module cabaret_solver_class

	use kind_parameters
	use global_data
	use data_manager_class
	use data_io_class
	use computational_domain_class
	use computational_mesh_class
	use boundary_conditions_class
	use field_pointers
	use table_approximated_real_gas_class
	use thermophysical_properties_class	
	use chemical_properties_class

	use viscosity_solver_class
	use fickean_diffusion_solver_class
	use fourier_heat_transfer_solver_class
	use chemical_kinetics_solver_class

	use mpi_communications_class

	use solver_options_class

	use riemann_solver5
	implicit none

#ifdef OMP
	include "omp_lib.h"
#endif

	private
	public	:: cabaret_solver, cabaret_solver_c

	type(field_scalar_flow)	,target	::	rho_f_new, p_f_new, e_i_f_new, v_s_f_new, E_f_f_new, T_f_new
	type(field_vector_flow)	,target	::	Y_f_new, v_f_new
	
#ifdef OMP
	integer(kind=omp_lock_kind)	,dimension(:,:,:)	,allocatable	:: lock
#endif	
	
	type cabaret_solver
		logical			:: diffusion_flag, viscosity_flag, heat_trans_flag, reactive_flag, sources_flag, hydrodynamics_flag, CFL_condition_flag
		real(dkind)		:: courant_fraction
		real(dkind)		:: time, time_step, initial_time_step
		
		type(chemical_kinetics_solver)		:: chem_kin_solver
		type(diffusion_solver)				:: diff_solver
		type(heat_transfer_solver)			:: heat_trans_solver
		type(viscosity_solver)				:: viscosity_solver	
		type(table_approximated_real_gas)	:: state_eq

		type(computational_domain)				:: domain
		type(mpi_communications)				:: mpi_support
		type(chemical_properties_pointer)		:: chem
		type(thermophysical_properties_pointer)	:: thermo
		type(computational_mesh_pointer)		:: mesh
		type(boundary_conditions_pointer)		:: boundary

		type(field_scalar_cons_pointer)	:: rho	, T	, p	, v_s, gamma, E_f	, e_i ,mol_mix_conc
		type(field_scalar_flow_pointer)	:: gamma_f_new, rho_f_new, p_f_new, e_i_f_new, v_s_f_new, E_f_f_new, T_f_new
		
		type(field_scalar_cons_pointer)	:: E_f_prod_chem, E_f_prod_heat, E_f_prod_diff, E_f_prod_visc

		type(field_vector_cons_pointer)	:: v, Y	, v_prod_visc
		type(field_vector_flow_pointer)	:: v_f_new, Y_f_new
		
		type(field_vector_cons_pointer)	:: Y_prod_chem, Y_prod_diff

		! Conservative variables
		real(dkind) ,dimension(:,:,:)	,allocatable    :: rho_old, p_old, E_f_old, e_i_old, E_f_prod, rho_prod, v_s_old, gamma_old
		real(dkind)	,dimension(:,:,:,:)	,allocatable	:: v_old, Y_old, v_prod, Y_prod

		! Flow variables
		real(dkind) ,dimension(:,:,:,:,:)	,allocatable    :: v_f, Y_f
		real(dkind) ,dimension(:,:,:,:)		,allocatable    :: rho_f, p_f, e_i_f, E_f_f, v_s_f
		! Quasi invariants

	contains
		procedure	,private	:: apply_boundary_conditions_main
		procedure	,private	:: apply_boundary_conditions_flow
		procedure				:: solve_problem
		procedure				:: solve_test_problem
		procedure				:: calculate_time_step
		procedure				:: get_time_step
		procedure				:: get_time
		procedure				:: set_CFL_coefficient
	end type

	interface	cabaret_solver_c
		module procedure	constructor
	end interface

contains

	type(cabaret_solver)	function constructor(manager,problem_data_io, problem_solver_options)
		type(data_manager)						,intent(inout)	:: manager
		type(data_io)							,intent(inout)	:: problem_data_io
		type(solver_options)					,intent(in)		:: problem_solver_options

		real(dkind)								:: calculation_time
		
		type(field_scalar_cons_pointer)	:: scal_ptr
		type(field_vector_cons_pointer)	:: vect_ptr
		type(field_tensor_cons_pointer)	:: tens_ptr		

		type(field_scalar_flow_pointer)	:: scal_f_ptr		
		type(field_vector_flow_pointer)	:: vect_f_ptr
		
		
		real(dkind)				:: spec_summ
		integer	,dimension(3,2)	:: cons_allocation_bounds, flow_allocation_bounds
		integer	,dimension(3,2)	:: flow_inner_loop, loop
		
		integer					:: dimensions, species_number
		integer					:: i, j, k, dim, dim1, spec
		real(dkind)	,dimension(3)	:: cell_size

		cons_allocation_bounds		= manager%domain%get_local_utter_cells_bounds()
		flow_allocation_bounds		= manager%domain%get_local_utter_faces_bounds()
		dimensions					= manager%domain%get_domain_dimensions()

		species_number			= manager%chemistry%chem_ptr%species_number
		
		cell_size				= manager%computational_mesh_pointer%mesh_ptr%get_cell_edges_length()
		
		constructor%diffusion_flag		= problem_solver_options%get_molecular_diffusion_flag()
		constructor%viscosity_flag		= problem_solver_options%get_viscosity_flag()
		constructor%heat_trans_flag		= problem_solver_options%get_heat_transfer_flag()
		constructor%reactive_flag		= problem_solver_options%get_chemical_reaction_flag()
		constructor%hydrodynamics_flag	= problem_solver_options%get_hydrodynamics_flag()
		constructor%courant_fraction	= problem_solver_options%get_CFL_condition_coefficient()
		constructor%CFL_condition_flag	= problem_solver_options%get_CFL_condition_flag()
		constructor%sources_flag		= .false.

		constructor%domain				= manager%domain
		constructor%mpi_support			= manager%mpi_communications
		constructor%chem%chem_ptr		=> manager%chemistry%chem_ptr
		constructor%boundary%bc_ptr		=> manager%boundary_conditions_pointer%bc_ptr
		constructor%mesh%mesh_ptr		=> manager%computational_mesh_pointer%mesh_ptr
		constructor%thermo%thermo_ptr	=> manager%thermophysics%thermo_ptr

		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'density')
		constructor%rho%s_ptr				=> scal_ptr%s_ptr
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'temperature')
		constructor%T%s_ptr					=> scal_ptr%s_ptr
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'pressure')
		constructor%p%s_ptr					=> scal_ptr%s_ptr
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'full_energy')
		constructor%E_f%s_ptr				=> scal_ptr%s_ptr
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'internal_energy')
		constructor%e_i%s_ptr				=> scal_ptr%s_ptr		
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'mixture_molar_concentration')
		constructor%mol_mix_conc%s_ptr		=> scal_ptr%s_ptr		
		
		call manager%create_scalar_field(rho_f_new	,'density_flow'				,'rho_f_new')
		constructor%rho_f_new%s_ptr 	=> rho_f_new		
		call manager%create_scalar_field(p_f_new	,'pressure_flow'			,'p_f_new')
		constructor%p_f_new%s_ptr 		=> p_f_new
		call manager%create_scalar_field(e_i_f_new	,'internal_energy_flow'		,'e_i_f_new')
		constructor%e_i_f_new%s_ptr 	=> e_i_f_new
		call manager%create_scalar_field(E_f_f_new	,'full_energy_flow'			,'E_f_f_new')
		constructor%E_f_f_new%s_ptr 	=> E_f_f_new
		call manager%create_scalar_field(v_s_f_new	,'velocity_of_sound_flow'	,'v_s_f_new')
		constructor%v_s_f_new%s_ptr 	=> v_s_f_new
		call manager%create_scalar_field(T_f_new	,'temperature_flow'			,'T_f_new')
		constructor%T_f_new%s_ptr 		=> T_f_new
		
		call manager%create_vector_field(Y_f_new,'specie_molar_concentration_flow'	,'Y_f_new',	'chemical')
		constructor%Y_f_new%v_ptr => Y_f_new		
		call manager%create_vector_field(v_f_new,'velocity_flow'					,'v_f_new',	'spatial')
		constructor%v_f_new%v_ptr => v_f_new	
		
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'velocity')
		constructor%v%v_ptr				=> vect_ptr%v_ptr		
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'specie_molar_concentration')
		constructor%Y%v_ptr				=> vect_ptr%v_ptr	
		
		if (constructor%reactive_flag) then
			constructor%chem_kin_solver		= chemical_kinetics_solver_c(manager)
			call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'energy_production_chemistry')
			constructor%E_f_prod_chem%s_ptr			=> scal_ptr%s_ptr
			call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'specie_production_chemistry')
			constructor%Y_prod_chem%v_ptr			=> vect_ptr%v_ptr
		end if

		if (constructor%diffusion_flag) then
			constructor%diff_solver			= diffusion_solver_c(manager)
			call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'energy_production_diffusion')
			constructor%E_f_prod_diff%s_ptr			=> scal_ptr%s_ptr			
			call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'specie_production_diffusion')
			constructor%Y_prod_diff%v_ptr			=> vect_ptr%v_ptr
		end if

		if (constructor%heat_trans_flag) then
			constructor%heat_trans_solver	= heat_transfer_solver_c(manager)
			call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'energy_production_heat_transfer')
			constructor%E_f_prod_heat%s_ptr			=> scal_ptr%s_ptr
		end if

		if(constructor%viscosity_flag) then
			constructor%viscosity_solver			= viscosity_solver_c(manager)
			call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'energy_production_viscosity')
			constructor%E_f_prod_visc%s_ptr			=> scal_ptr%s_ptr
			call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'velocity_production_viscosity')
			constructor%v_prod_visc%v_ptr			=> vect_ptr%v_ptr
		end if			
		
		constructor%state_eq	=	table_approximated_real_gas_c(manager)
		
		call manager%get_flow_field_pointer_by_name(scal_f_ptr,vect_f_ptr,'adiabatic_index_flow')
		constructor%gamma_f_new%s_ptr	=> scal_f_ptr%s_ptr				
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'adiabatic_index')
		constructor%gamma%s_ptr			=> scal_ptr%s_ptr		
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'velocity_of_sound')
		constructor%v_s%s_ptr			=> scal_ptr%s_ptr		
		
		problem_data_io				= data_io_c(manager,calculation_time)
		
		if(problem_data_io%get_load_counter() /= 0) then
			call problem_data_io%add_io_scalar_cons_field(constructor%E_f)
			call problem_data_io%add_io_scalar_cons_field(constructor%gamma)
			call problem_data_io%add_io_scalar_flow_field(constructor%rho_f_new)
			call problem_data_io%add_io_scalar_flow_field(constructor%p_f_new)
			call problem_data_io%add_io_scalar_flow_field(constructor%E_f_f_new)
			call problem_data_io%add_io_vector_flow_field(constructor%Y_f_new)
			call problem_data_io%add_io_vector_flow_field(constructor%v_f_new)
		end if

		call problem_data_io%input_all_data()

		if(problem_data_io%get_load_counter() == 1) then
			call problem_data_io%add_io_scalar_cons_field(constructor%E_f)
			call problem_data_io%add_io_scalar_cons_field(constructor%gamma)
			call problem_data_io%add_io_scalar_flow_field(constructor%rho_f_new)
			call problem_data_io%add_io_scalar_flow_field(constructor%p_f_new)
			call problem_data_io%add_io_scalar_flow_field(constructor%E_f_f_new)
			call problem_data_io%add_io_vector_flow_field(constructor%Y_f_new)
			call problem_data_io%add_io_vector_flow_field(constructor%v_f_new)
		end if		
					
		if(problem_data_io%get_load_counter() == 1) then
			call constructor%state_eq%apply_state_equation_for_initial_conditions()
		else
			call constructor%state_eq%apply_state_equation()
			call constructor%state_eq%apply_boundary_conditions_for_initial_conditions()
		end if		
		
		call constructor%mpi_support%exchange_conservative_scalar_field(constructor%p%s_ptr)
		call constructor%mpi_support%exchange_conservative_scalar_field(constructor%rho%s_ptr)
		call constructor%mpi_support%exchange_conservative_scalar_field(constructor%E_f%s_ptr)
		call constructor%mpi_support%exchange_conservative_scalar_field(constructor%T%s_ptr)
		call constructor%mpi_support%exchange_conservative_scalar_field(constructor%v_s%s_ptr)

		call constructor%mpi_support%exchange_conservative_vector_field(constructor%Y%v_ptr)
		call constructor%mpi_support%exchange_conservative_vector_field(constructor%v%v_ptr)

		call constructor%mpi_support%exchange_boundary_conditions_markers(constructor%boundary%bc_ptr)
		call constructor%mpi_support%exchange_mesh(constructor%mesh%mesh_ptr)

		allocate(constructor%rho_old(	cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
										
		allocate(constructor%p_old(		cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
										
		allocate(constructor%E_f_old(	cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
								
		allocate(constructor%e_i_old(	cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
									
		allocate(constructor%E_f_prod(	cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
									
		allocate(constructor%rho_prod(	cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
									
		allocate(constructor%v_s_old(	cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
									
		allocate(constructor%gamma_old(	cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
		
		allocate(constructor%v_old(		dimensions						, &
										cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))

		allocate(constructor%v_prod(	dimensions						, &
										cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
									
		allocate(constructor%Y_old(		species_number					, &
										cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
								
		allocate(constructor%Y_prod(	species_number					, &
										cons_allocation_bounds(1,1):cons_allocation_bounds(1,2), &
										cons_allocation_bounds(2,1):cons_allocation_bounds(2,2), &
										cons_allocation_bounds(3,1):cons_allocation_bounds(3,2)))
										
			
										
		
		allocate(constructor%rho_f(		dimensions						, &
										flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
										flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
										flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))
								
		allocate(constructor%p_f(		dimensions						, &
										flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
										flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
										flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))
										
		allocate(constructor%E_f_f(		dimensions						, &
										flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
										flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
										flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))	
										
		allocate(constructor%e_i_f(		dimensions						, &
										flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
										flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
										flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))
										
		allocate(constructor%v_s_f(		dimensions						, &
										flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
										flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
										flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))	
										
		allocate(constructor%v_f(		dimensions						, &
										dimensions						, &
										flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
										flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
										flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))	
								
		allocate(constructor%Y_f(		species_number					, &
										dimensions						, &
										flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
										flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
										flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))		

		flow_inner_loop	= manager%domain%get_local_inner_faces_bounds()									
	
		
#ifdef OMP	
		allocate(lock(	flow_allocation_bounds(1,1):flow_allocation_bounds(1,2), &
						flow_allocation_bounds(2,1):flow_allocation_bounds(2,2), &
						flow_allocation_bounds(3,1):flow_allocation_bounds(3,2)))

		do k = flow_inner_loop(3,1),flow_inner_loop(3,2)
		do j = flow_inner_loop(2,1),flow_inner_loop(2,2)
		do i = flow_inner_loop(1,1),flow_inner_loop(1,2)		
			call omp_init_lock(lock(i,j,k))			
		end do
		end do
		end do
#endif											
										
		if (problem_data_io%get_load_counter() == 1) then

			constructor%p_f(:,:,:,:)	= 0.0_dkind								
			constructor%rho_f(:,:,:,:)	= 0.0_dkind
			constructor%Y_f(:,:,:,:,:)	= 0.0_dkind
			constructor%v_f(:,:,:,:,:)	= 0.0_dkind

			do dim = 1, dimensions		

				loop = flow_inner_loop

				do dim1 = 1,dimensions
					loop(dim1,2) = flow_inner_loop(dim1,2) - (1 - I_m(dim1,dim))
				end do

				do k = loop(3,1),loop(3,2)
				do j = loop(2,1),loop(2,2) 
				do i = loop(1,1),loop(1,2) 
						
			
					!	if ((constructor%boundary%bc_ptr%bc_markers(i,j,k) == 0).and.(constructor%boundary%bc_ptr%bc_markers(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)) == 0)) then
							constructor%p_f(dim,i,j,k)		=	0.5_dkind * (constructor%p%s_ptr%cells(i,j,k)	+ constructor%p%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))	
							constructor%rho_f(dim,i,j,k)	=	0.5_dkind * (constructor%rho%s_ptr%cells(i,j,k)	+ constructor%rho%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))	
							constructor%E_f_f(dim,i,j,k)	=	0.5_dkind * (constructor%E_f%s_ptr%cells(i,j,k)	+ constructor%E_f%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))
							constructor%v_s_f(dim,i,j,k)	=	0.5_dkind * (constructor%v_s%s_ptr%cells(i,j,k)	+ constructor%v_s%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))
							spec_summ = 0.0_dkind
							do spec = 1, species_number
								constructor%Y_f(spec,dim,i,j,k) = 0.5_dkind * (constructor%Y%v_ptr%pr(spec)%cells(i,j,k) + constructor%Y%v_ptr%pr(spec)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))
								spec_summ = spec_summ + max(constructor%Y_f(spec,dim,i,j,k), 0.0_dkind)
							end do

							do spec = 1,species_number
								constructor%Y_f(spec,dim,i,j,k) = max(constructor%Y_f(spec,dim,i,j,k), 0.0_dkind) / spec_summ
							end do

							do dim1 = 1, dimensions
								constructor%v_f(dim1,dim,i,j,k) = 0.5_dkind * (constructor%v%v_ptr%pr(dim1)%cells(i,j,k) + constructor%v%v_ptr%pr(dim1)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)) )
							end do

							if (constructor%boundary%bc_ptr%bc_markers(i,j,k) /= 0) then
								constructor%p_f(dim,i,j,k)		=	constructor%p%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))
								constructor%rho_f(dim,i,j,k)	=	constructor%rho%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))
								constructor%E_f_f(dim,i,j,k)	=	constructor%E_f%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))
								constructor%v_s_f(dim,i,j,k)	=	constructor%v_s%s_ptr%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))

								spec_summ = 0.0_dkind
								do spec = 1, species_number
									constructor%Y_f(spec,dim,i,j,k) =  constructor%Y%v_ptr%pr(spec)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))
									spec_summ = spec_summ + max(constructor%Y_f(spec,dim,i,j,k), 0.0_dkind)
								end do

								do spec = 1,species_number
									constructor%Y_f(spec,dim,i,j,k) = max(constructor%Y_f(spec,dim,i,j,k), 0.0_dkind) / spec_summ
								end do

								do dim1 = 1, dimensions
									constructor%v_f(dim1,dim,i,j,k) =	constructor%v%v_ptr%pr(dim1)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))
								end do
							end if

							if (constructor%boundary%bc_ptr%bc_markers(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)) /= 0) then
								constructor%p_f(dim,i,j,k)		=	constructor%p%s_ptr%cells(i,j,k)	
								constructor%rho_f(dim,i,j,k)	=	constructor%rho%s_ptr%cells(i,j,k)	
								constructor%E_f_f(dim,i,j,k)	=	constructor%E_f%s_ptr%cells(i,j,k)
								constructor%v_s_f(dim,i,j,k)	=	constructor%v_s%s_ptr%cells(i,j,k)
								
								spec_summ = 0.0_dkind
								do spec = 1, species_number
									constructor%Y_f(spec,dim,i,j,k) = constructor%Y%v_ptr%pr(spec)%cells(i,j,k)
									spec_summ = spec_summ + max(constructor%Y_f(spec,dim,i,j,k), 0.0_dkind)
								end do

								do spec = 1,species_number
									constructor%Y_f(spec,dim,i,j,k) = max(constructor%Y_f(spec,dim,i,j,k), 0.0_dkind) / spec_summ
								end do

								do dim1 = 1, dimensions
									constructor%v_f(dim1,dim,i,j,k) =	constructor%v%v_ptr%pr(dim1)%cells(i,j,k)
								end do

							end if
					!	end if
				end do										
				end do	
				end do	
			end do

			do spec = 1,species_number
				constructor%Y_f_new%v_ptr%pr(spec)%cells(:,:,:,:) = constructor%Y_f(spec,:,:,:,:)			
			end do
			
			do dim = 1,dimensions
				constructor%v_f_new%v_ptr%pr(dim)%cells(:,:,:,:) = constructor%v_f(dim,:,:,:,:)    
			end do
		
			constructor%p_f_new%s_ptr%cells(:,:,:,:)	= constructor%p_f     
			constructor%rho_f_new%s_ptr%cells(:,:,:,:)	= constructor%rho_f   
			constructor%E_f_f_new%s_ptr%cells(:,:,:,:)	= constructor%E_f_f	
			constructor%v_s_f_new%s_ptr%cells(:,:,:,:)	= constructor%v_s_f
			
		end if

		call constructor%mpi_support%exchange_flow_scalar_field(constructor%p_f_new%s_ptr)
		call constructor%mpi_support%exchange_flow_scalar_field(constructor%rho_f_new%s_ptr)
		call constructor%mpi_support%exchange_flow_scalar_field(constructor%E_f_f_new%s_ptr)	
		call constructor%mpi_support%exchange_flow_scalar_field(constructor%v_s_f_new%s_ptr)
		call constructor%mpi_support%exchange_flow_vector_field(constructor%Y_f_new%v_ptr)
		call constructor%mpi_support%exchange_flow_vector_field(constructor%v_f_new%v_ptr)
	
		do spec = 1,species_number
			constructor%Y_f(spec,:,:,:,:)	= constructor%Y_f_new%v_ptr%pr(spec)%cells		
		end do
		
		do dim = 1,dimensions
			constructor%v_f(dim,:,:,:,:)     = constructor%v_f_new%v_ptr%pr(dim)%cells
		end do
	

		constructor%time		= calculation_time
		constructor%time_step	=	problem_solver_options%get_initial_time_step()
		constructor%initial_time_step = problem_solver_options%get_initial_time_step()
		
		call constructor%state_eq%apply_state_equation_flow_variables_for_IC()

		call constructor%apply_boundary_conditions_main()
		
        constructor%p_f     = constructor%p_f_new%s_ptr%cells
        constructor%rho_f   = constructor%rho_f_new%s_ptr%cells
		constructor%E_f_f	= constructor%E_f_f_new%s_ptr%cells
		constructor%v_s_f	= constructor%v_s_f_new%s_ptr%cells

	end function

	subroutine solve_test_problem(this)
		class(cabaret_solver)	,intent(inout)	:: this

		associate(	rho			=> this%rho%s_ptr, &
					rho_f_new	=> this%rho_f_new%s_ptr, &
					v_f_new		=> this%v_f_new%v_ptr, &
					p			=> this%p%s_ptr	) 

			rho%cells = this%domain%get_processor_rank()
			rho_f_new%cells = this%domain%get_processor_rank()
			v_f_new%pr(1)%cells	= this%domain%get_processor_rank()
			v_f_new%pr(2)%cells	= this%domain%get_processor_rank()*10

			call this%mpi_support%exchange_conservative_scalar_field(rho)

			call this%mpi_support%exchange_flow_scalar_field(rho_f_new)

			call this%mpi_support%exchange_flow_vector_field(v_f_new)

		end associate

	end subroutine


	subroutine solve_problem(this)
		class(cabaret_solver)	,intent(inout)	:: this
    
		real(dkind)	,dimension(2)						:: r, q, r_corrected, q_corrected, r_new, q_new
		real(dkind)	,dimension(:,:)	,allocatable	,save	:: v_inv, v_inv_corrected, v_inv_new
		real(dkind)	,dimension(:)	,allocatable	,save	:: v_inv_half, v_inv_old
		real(dkind)	,dimension(:,:)	,allocatable	,save	:: Y_inv, Y_inv_corrected, y_inv_new
		real(dkind)	,dimension(:)	,allocatable	,save	:: Y_inv_half, Y_inv_old

		real(dkind)					:: r_half, q_half, R_old, Q_old
		real(dkind)					:: G_half, G_half_old	, G_half_lower, G_half_higher
		
		real(dkind)	,dimension(3)	:: characteristic_speed

		real(dkind)	:: v_f_approx, v_s_f_approx
		real(dkind)	:: v_f_approx_lower, v_f_approx_higher

		real(dkind)	:: g_inv, alpha = 0.005_dkind, alpha_loc
		real(dkind)	:: f, corr, diss_l, diss_r, diss = 1.0_dkind
		integer		,save :: dissipator_active = 0
		real(dkind) :: max_inv, min_inv, maxmin_inv
		real(dkind) :: mean_higher, mean_lower
		real(dkind)	:: sources
		real(dkind)	:: mean_sources
		real(dkind)	:: summ_frac
		real(dkind)	:: energy_output_time	= 2.0e-07_dkind
		real(dkind)	:: energy_output_radii	= 4.0e-04_dkind
		real(dkind)	:: energy_source = 1.9e+04_dkind
		real(dkind)	,save	:: energy_output_rho = 0.0_dkind
		real(dkind)	,save	:: energy_output = 0.0_dkind
		integer		,save	:: energy_output_flag = 0 
		
		!real(dkind)	:: r_inf, q_inf, s_inf
		real(dkind)	,parameter	:: u_inf		= 0.0
		real(dkind)	,parameter	:: p_inf		= 101325.000000000_dkind
		real(dkind)	,parameter	:: rho_inf		= 0.487471044003493_dkind
		real(dkind)	,parameter	:: c_inf		= 539.709011600784_dkind
		real(dkind)	,parameter	:: gamma_inf	= 1.40137_dkind
		real(dkind)			:: g_inf		= 1.0_dkind / rho_inf / c_inf
		real(dkind)	,save	:: q_inf		= u_inf - p_inf / rho_inf / c_inf
	
		real(dkind)	:: spec_summ, rho_Y
		
		real(dkind), save	:: Mach_old
		real(dkind)			:: Mach
		real(dkind)			:: flow_Mach, cons_Mach
		real(dkind)			:: Mach_rise, Max_Mach_rise
		integer				:: Max_Mach_rise_i, Max_Mach_rise_j
		real(dkind)			:: Max_v_s, Min_v_s
		
		integer				:: nu
		
		integer					:: sign, bound_number

		integer	:: dimensions, species_number
		character(len=20)	:: coordinate_system
		integer	,dimension(3,2)	:: cons_inner_loop, cons_utter_loop, flow_utter_loop, flow_inner_loop
		integer	,dimension(3,2)	:: loop
		real(dkind)	,dimension(3)	:: cell_size

		integer			:: i,j,k,plus,dim,dim1,dim2,spec,iter		

		integer	:: thread
		character*1  :: use_riemann_mod = '0'
		call getenv( 'USE_RIEMANN_MOD', use_riemann_mod )
		
		dimensions		= this%domain%get_domain_dimensions()
		species_number	= this%chem%chem_ptr%species_number

		coordinate_system	= this%domain%get_coordinate_system_name()
		
		cons_inner_loop	= this%domain%get_local_inner_cells_bounds()
		cons_utter_loop = this%domain%get_local_utter_cells_bounds()

		flow_utter_loop = this%domain%get_local_utter_faces_bounds()
		flow_inner_loop = this%domain%get_local_inner_faces_bounds()

		cell_size		= this%mesh%mesh_ptr%get_cell_edges_length()

		if (.not.allocated(v_inv)) then
			allocate(v_inv(dimensions,2), v_inv_corrected(dimensions,2), v_inv_new(dimensions,2))
			allocate(v_inv_half(dimensions), v_inv_old(dimensions))
			allocate(Y_inv(species_number,2), Y_inv_corrected(species_number,2), y_inv_new(species_number,2))
			allocate(Y_inv_half(species_number), Y_inv_old(species_number))
		end if

		if (this%CFL_condition_flag) then
			call this%calculate_time_step()
		end if

		this%time	= this%time + this%time_step		

		!Max_v_s		= 0.0_dkind
		!Min_v_s		= 10000.0_dkind
		
		associate(	rho			=> this%rho%s_ptr		, &
					p			=> this%p%s_ptr			, &
					E_f			=> this%E_f%s_ptr		, &
					e_i			=> this%e_i%s_ptr		, &
					v_s			=> this%v_s%s_ptr		, &
					gamma		=> this%gamma%s_ptr		, &
					mol_mix_conc	=>this%mol_mix_conc%s_ptr, &
					T			=>this%T%s_ptr, &

					v			=> this%v%v_ptr	, &
					Y			=> this%Y%v_ptr	, &
					
					v_f			=> this%v_f		, &
					rho_f		=> this%rho_f	, &
					E_f_f		=> this%E_f_f	, &
					e_i_f		=> this%e_i_f	, &
					p_f			=> this%p_f		, &
					v_s_f		=> this%v_s_f	, & 
					Y_f			=> this%Y_f		, &
					
					rho_old		=> this%rho_old	, &
					v_old		=> this%v_old	, &
					E_f_old		=> this%E_f_old	,&
					Y_old		=> this%Y_old	,&
					p_old		=> this%p_old	,&
					v_s_old		=> this%v_s_old	,&
					gamma_old	=> this%gamma_old	, &
					
					p_f_new		=> this%p_f_new%s_ptr		, &	
					rho_f_new	=> this%rho_f_new%s_ptr		, &
					v_s_f_new	=> this%v_s_f_new%s_ptr		, &
					E_f_f_new	=> this%E_f_f_new%s_ptr		, &
					e_i_f_new	=> this%e_i_f_new%s_ptr		, &
					Y_f_new		=> this%Y_f_new%v_ptr		, &
					v_f_new		=> this%v_f_new%v_ptr		, &
					gamma_f_new	=> this%gamma_f_new%s_ptr	, &
					
					v_prod_visc		=> this%v_prod_visc%v_ptr	, &
					Y_prod_chem		=> this%Y_prod_chem%v_ptr	, &
					Y_prod_diff		=> this%Y_prod_diff%v_ptr	, &
					E_f_prod_chem 	=> this%E_f_prod_chem%s_ptr	, &
					E_f_prod_heat	=> this%E_f_prod_heat%s_ptr	, &
					E_f_prod_visc	=> this%E_f_prod_visc%s_ptr	, &
					E_f_prod_diff	=> this%E_f_prod_diff%s_ptr	, &
					E_f_prod		=> this%E_f_prod			, &
					v_prod			=> this%v_prod				, &
					Y_prod			=> this%Y_prod				, &
					rho_prod		=> this%rho_prod			, &

					bc				=> this%boundary%bc_ptr		, &
					mesh			=> this%mesh%mesh_ptr)
										
		call this%apply_boundary_conditions_main()						

		select case(coordinate_system)
			case ('cartesian')	
			case ('cylindrical')
				! x -> z, y -> r
				nu = 2
			case ('spherical')
				! x -> r
				nu = 3 
		end select		
		
		call this%mpi_support%exchange_conservative_scalar_field(p)
		call this%mpi_support%exchange_conservative_scalar_field(rho)
		call this%mpi_support%exchange_conservative_scalar_field(v_s)
		call this%mpi_support%exchange_conservative_scalar_field(E_f)

		call this%mpi_support%exchange_conservative_vector_field(Y)
		call this%mpi_support%exchange_conservative_vector_field(v)

		rho_old		= rho%cells
		E_f_old		= E_f%cells
		v_s_old		= v_s%cells
		p_old		= p%cells

		do spec = 1,species_number
			Y_old(spec,:,:,:)		=	Y%pr(spec)%cells
		end do

		do dim = 1,dimensions
			v_old(dim,:,:,:)		=	v%pr(dim)%cells
		end do	

		!$omp parallel default(none)  private(i,j,k,dim,dim1,spec,spec_summ) , &
		!$omp& firstprivate(this) , &
		!$omp& shared(cons_inner_loop,bc,dimensions,species_number,p,p_old,p_f,rho,rho_f,rho_prod,rho_old,v,v_f,v_prod,v_old,v_s,v_s_old,Max_v_s,Min_v_s,Y,Y_f,Y_prod,Y_old,E_f,E_f_f,E_f_prod,E_F_old,mesh,cell_size,nu,coordinate_system)
		!$omp do collapse(3) schedule(guided) reduction(max:Max_v_s) reduction(min:Min_v_s)	 		
		do k = cons_inner_loop(3,1),cons_inner_loop(3,2)
		do j = cons_inner_loop(2,1),cons_inner_loop(2,2)
		do i = cons_inner_loop(1,1),cons_inner_loop(1,2)
			if(bc%bc_markers(i,j,k) == 0) then
				
				rho%cells(i,j,k)	= 0.0_dkind
				E_f%cells(i,j,k)	= 0.0_dkind

				!if (v_s_old(i,j,k) > Max_v_s) then
				!	Max_v_s = v_s_old(i,j,k)
				!end if

				!if (v_s_old(i,j,k) < Min_v_s) then
				!	Min_v_s = v_s_old(i,j,k)
				!end if
				
				do spec = 1,species_number
					Y%pr(spec)%cells(i,j,k)	=	0.0_dkind 
				end do
		  
				do dim = 1,dimensions
					v%pr(dim)%cells(i,j,k)	=	0.0_dkind 		
				end do				
			 
				do dim = 1,dimensions
					rho%cells(i,j,k)	=	rho%cells(i,j,k)	- (	rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) -	rho_f(dim,i,j,k)*v_f(dim,dim,i,j,k))/cell_size(1)
					if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
						rho%cells(i,j,k)	=	rho%cells(i,j,k) - 2.0_dkind * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																			 * 0.5_dkind * (rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	rho_f(dim,i,j,k)*v_f(dim,dim,i,j,k))	&
																			 * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 	
					end if		
				end do
				
				rho%cells(i,j,k)		=	rho_old(i,j,k)	+  0.5_dkind*this%time_step * rho%cells(i,j,k)
	
				spec_summ = 0.0_dkind
				do spec = 1,species_number
					do	dim = 1,dimensions
						Y%pr(spec)%cells(i,j,k)	=  Y%pr(spec)%cells(i,j,k)	-	(		rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*Y_f(spec,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	&
																					-	rho_f(dim,i,j,k)*Y_f(spec,dim,i,j,k)*v_f(dim,dim,i,j,k))/cell_size(1)
																					
						if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
							Y%pr(spec)%cells(i,j,k)	=	Y%pr(spec)%cells(i,j,k) - 2.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																							 * 0.5_dkind * (rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*Y_f(spec,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	rho_f(dim,i,j,k)*Y_f(spec,dim,i,j,k)*v_f(dim,dim,i,j,k))	&
																							 * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 	
						end if																	
					end do	

					
					Y%pr(spec)%cells(i,j,k)		=   rho_old(i,j,k)  *	Y_old(spec,i,j,k) + 0.5_dkind*this%time_step * Y%pr(spec)%cells(i,j,k)
					Y%pr(spec)%cells(i,j,k)		=  Y%pr(spec)%cells(i,j,k)/rho%cells(i,j,k)
					
					spec_summ = spec_summ + max(Y%pr(spec)%cells(i,j,k), 0.0_dkind)
				end do
 					
				!if (spec_summ < 0) then
				!	print *, 'Interm conservative species exception ', i,j,k
				!	stop
				!end if
				
				do spec = 1,species_number
					Y%pr(spec)%cells(i,j,k) = max(Y%pr(spec)%cells(i,j,k), 0.0_dkind) / spec_summ 
				end do

				do dim = 1,dimensions
					do dim1 = 1,dimensions
						v%pr(dim)%cells(i,j,k)	=  v%pr(dim)%cells(i,j,k)	-	(		rho_f(dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))*v_f(dim,dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))*v_f(dim1,dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))	&
																					-	rho_f(dim1,i,j,k)*v_f(dim,dim1,i,j,k)*v_f(dim1,dim1,i,j,k)) /cell_size(1)

						if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
							v%pr(dim)%cells(i,j,k)	=	v%pr(dim)%cells(i,j,k) - 2.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																							* 0.5_dkind * (rho_f(dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))*v_f(dim,dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))*v_f(dim1,dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3)) +	rho_f(dim1,i,j,k)*v_f(dim,dim1,i,j,k)*v_f(dim1,dim1,i,j,k))	&
																							* ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 	
						end if		

					end do

					v%pr(dim)%cells(i,j,k)	=	v%pr(dim)%cells(i,j,k)	-	 ( p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - p_f(dim,i,j,k)) /cell_size(1)
					
					v%pr(dim)%cells(i,j,k)	=	rho_old(i,j,k)*v_old(dim,i,j,k) + 0.5_dkind*this%time_step*v%pr(dim)%cells(i,j,k) 
					v%pr(dim)%cells(i,j,k)	=	v%pr(dim)%cells(i,j,k) /rho%cells(i,j,k)
	
				end do	
    
				do dim = 1,dimensions
					E_f%cells(i,j,k)		= 	E_f%cells(i,j,k)		-	((rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*E_f_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+	p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	&
																		-	(rho_f(dim,i,j,k)*E_f_f(dim,i,j,k)																		+	p_f(dim,i,j,k))									*v_f(dim,dim,i,j,k))/cell_size(1)
								
					if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
						E_f%cells(i,j,k)	=	E_f%cells(i,j,k) - 2.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																			  * 0.5_dkind * ((rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*E_f_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+	p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	(rho_f(dim,i,j,k)*E_f_f(dim,i,j,k)	+	p_f(dim,i,j,k))*v_f(dim,dim,i,j,k))	&
																			  * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 	
					end if
				end do	
				
				E_f%cells(i,j,k)		=	rho_old(i,j,k) * E_f_old(i,j,k)  + 0.5_dkind*this%time_step* E_f%cells(i,j,k)
				E_f%cells(i,j,k)		=	E_f%cells(i,j,k) / rho%cells(i,j,k) 
				
			end if
		end do
		end do
		end do
		!$omp end do nowait		
		!$omp end parallel				
		
				
		!print *, 'Max_v_s', Max_v_s
		!print *, 'Min_v_s', Min_v_s
		
		! ********** Conservative variables state eq *******************	
		call this%state_eq%apply_state_equation() 
		! **************************************************************

		! Block one mpi_exchange
		call this%mpi_support%exchange_conservative_scalar_field(p)
		call this%mpi_support%exchange_conservative_scalar_field(rho)
		call this%mpi_support%exchange_conservative_scalar_field(E_f)
		call this%mpi_support%exchange_conservative_scalar_field(v_s)
		call this%mpi_support%exchange_conservative_scalar_field(gamma)

		
		call this%mpi_support%exchange_conservative_vector_field(Y)
		call this%mpi_support%exchange_conservative_vector_field(v)

		!$omp parallel default(none)  private(i,j,k,dim,dim1,spec) , &
		!$omp& firstprivate(this) , &
		!$omp& shared(flow_utter_loop,p_f_new,rho_f_new,v_f_new,Y_f_new,species_number,dimensions)
		do dim = 1,dimensions
			!$omp do collapse(3) schedule(guided)			
			do k = flow_utter_loop(3,1),flow_utter_loop(3,2)
			do j = flow_utter_loop(2,1),flow_utter_loop(2,2)
			do i = flow_utter_loop(1,1),flow_utter_loop(1,2)		
			
				p_f_new%cells(dim,i,j,k)	= 0.0_dkind
				rho_f_new%cells(dim,i,j,k)	= 0.0_dkind	
		
				do dim1 = 1,dimensions
					v_f_new%pr(dim1)%cells(dim,i,j,k)	= 0.0_dkind
				end do
				do spec = 1,species_number
					Y_f_new%pr(spec)%cells(dim,i,j,k)	= 0.0_dkind		
				end do		
			end do	
			end do
			end do
			!$omp end do nowait
		end do
		!$omp end parallel		
		
		!$omp parallel default(none)  private(thread,i,j,k,dim,dim1,loop,G_half,G_half_old,G_half_lower,G_half_higher,r,R_half,R_old,q,Q_half,Q_old,v_inv,v_inv_half,v_inv_old,r_new,q_new,v_inv_new,f,g_inv,max_inv,min_inv,maxmin_inv,r_corrected,q_corrected,v_inv_corrected,v_f_approx,v_s_f_approx,characteristic_speed,diss_l,diss_r,alpha_loc,sign,bound_number) , &
		!$omp& firstprivate(this) , &
		!$omp& shared(cons_utter_loop,cons_inner_loop,dimensions,bc,v_s,v_s_old,rho,rho_old,p,p_old,v,v_old,E_f,gamma,p_f,v_f,rho_f,rho_prod,v_prod,E_f_prod,p_f_new,rho_f_new,v_f_new,Max_v_s,Min_v_s,diss,alpha,dissipator_active,mesh,cell_size,lock,coordinate_system)
		do dim = 1,dimensions
			! Avoid looping in transverse direction in ghost cells

			thread = 0
		
			loop(3,1) = cons_utter_loop(3,1)*I_m(dim,3) + cons_inner_loop(3,1)*(1 - I_m(dim,3))
			loop(3,2) = cons_utter_loop(3,2)*I_m(dim,3) + cons_inner_loop(3,2)*(1 - I_m(dim,3))

			loop(2,1) = cons_utter_loop(2,1)*I_m(dim,2) + cons_inner_loop(2,1)*(1 - I_m(dim,2))
			loop(2,2) = cons_utter_loop(2,2)*I_m(dim,2) + cons_inner_loop(2,2)*(1 - I_m(dim,2))	

			loop(1,1) = cons_utter_loop(1,1)*I_m(dim,1) + cons_inner_loop(1,1)*(1 - I_m(dim,1))
			loop(1,2) = cons_utter_loop(1,2)*I_m(dim,1) + cons_inner_loop(1,2)*(1 - I_m(dim,1))						
			
			!$omp do collapse(3) schedule(guided)				
			do k = loop(3,1),loop(3,2)
			do j = loop(2,1),loop(2,2)
			do i = loop(1,1),loop(1,2)

				if(bc%bc_markers(i,j,k) == 0) then

					G_half			= 1.0_dkind / (v_s%cells(i,j,k)*rho%cells(i,j,k))
					G_half_old		= 1.0_dkind / (v_s_old(i,j,k)*rho_old(i,j,k))

					! *********** Riemann quasi invariants *************************

					! ********* Lower invariants ***********
					
					r(1) 	= v_f(dim,dim,i,j,k)									+ G_half*p_f(dim,i,j,k)
					r(2) 	= v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+ G_half*p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
					R_half	= v%pr(dim)%cells(i,j,k)								+ G_half*(p%cells(i,j,k))
					R_old	= v_old(dim,i,j,k)										+ G_half*(p_old(i,j,k))
					
					q(1) 	= v_f(dim,dim,i,j,k)									- G_half*p_f(dim,i,j,k)
					q(2) 	= v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	- G_half*p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
					Q_half	= v%pr(dim)%cells(i,j,k)								- G_half*(p%cells(i,j,k))
					Q_old	= v_old(dim,i,j,k)										- G_half*(p_old(i,j,k))

					do dim1 = 1,dimensions
						if (dim1 == dim) then
							v_inv(dim1,1)		= p_f(dim1,i,j,k)										- v_s%cells(i,j,k)**2*rho_f(dim1,i,j,k)
							v_inv(dim1,2)		= p_f(dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))	- v_s%cells(i,j,k)**2*rho_f(dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3)) 
							v_inv_half(dim1)	= p%cells(i,j,k)										- v_s%cells(i,j,k)**2*rho%cells(i,j,k)
							v_inv_old(dim1)		= p_old(i,j,k)											- v_s%cells(i,j,k)**2*rho_old(i,j,k)
						else
							v_inv(dim1,1)		= v_f(dim1,dim,i,j,k)
							v_inv(dim1,2)		= v_f(dim1,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
							v_inv_half(dim1)	= v%pr(dim1)%cells(i,j,k)
							v_inv_old(dim1)		= v_old(dim1,i,j,k)
						end if
					end do
			
				
					! ******************* Linear interpolation *********************
					
					diss_l = 0.0_dkind
					diss_r = 0.0_dkind
					
					!if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,1) ) then
					!	if (( v_s_f(dim,i,j,k) > (max(v_s%cells(i,j,k),v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))) + 100.0_dkind))	&
					!	.or.( v_s_f(dim,i,j,k) < (min(v_s%cells(i,j,k),v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))) - 100.0_dkind))) then
					!		diss_l = diss
					!		print *, 'Left dissipator active: ', dim, i,j,k, v_s_f(dim,i,j,k), v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)), v_s%cells(i,j,k)
					!		dissipator_active = dissipator_active + 1
					!		print *, 'Activation count: ',dissipator_active
					!	end if
					!end if
     !
					!if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) ) then
					!	if (( v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) > (max(v_s%cells(i,j,k),v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))) + 100.0_dkind))	&
					!	.or.( v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) < (min(v_s%cells(i,j,k),v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))) - 100.0_dkind))) then 
					!		diss_r = diss
					!		print *, 'Right dissipator active: ', dim, i,j,k, v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), v_s%cells(i,j,k) 
					!		dissipator_active = dissipator_active + 1
					!		print *, 'Activation count: ',dissipator_active	
					!	end if
					!end if
					
					alpha_loc = alpha
					if (( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) ).and.( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) )) then
						if (( v_s%cells(i,j,k) > (max(v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)),v_s_f(dim,i,j,k)) + 100.0_dkind))	&
						.or.( v_s%cells(i,j,k) < (min(v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)),v_s_f(dim,i,j,k)) - 100.0_dkind))) then 
							alpha_loc = alpha
							print *, 'Right dissipator active: ', dim, i,j,k, v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), v_s_f(dim,i,j,k), v_s%cells(i,j,k) 
							dissipator_active = dissipator_active + 1
							print *, 'Activation count: ',dissipator_active	
						end if
					end if
					
					r_new(1) = (2.0_dkind*R_half - (1.0_dkind-diss_l)*r(2))/(1.0_dkind+diss_l)
					q_new(1) = (2.0_dkind*Q_half - (1.0_dkind-diss_l)*q(2))/(1.0_dkind+diss_l)
	
					r_new(2) = (2.0_dkind*R_half - (1.0_dkind-diss_r)*r(1))/(1.0_dkind+diss_r)
					q_new(2) = (2.0_dkind*Q_half - (1.0_dkind-diss_r)*q(1))/(1.0_dkind+diss_r)				
				
					do dim1 = 1,dimensions
						v_inv_new(dim1,1)	= (2.0_dkind*v_inv_half(dim1) - (1.0_dkind-diss_l)*v_inv(dim1,2))/(1.0_dkind+diss_l)
						v_inv_new(dim1,2)	= (2.0_dkind*v_inv_half(dim1) - (1.0_dkind-diss_r)*v_inv(dim1,1))/(1.0_dkind+diss_r)
					end do

					! **************** Non-linear flow correction ******************

					g_inv = ((R_half - R_old)/(0.5_dkind*this%time_step) + (v%pr(dim)%cells(i,j,k) + v_s%cells(i,j,k))*(r(2) - r(1))/cell_size(1))

					max_inv = max(r(1),R_half,r(2)) + g_inv*this%time_step
					min_inv = min(r(1),R_half,r(2)) + g_inv*this%time_step
					maxmin_inv = abs(max_inv - min_inv)

				!	if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
				!		if (abs(max_inv) > 1e-02) then
				!			if(abs(maxmin_inv) > 1.0e-02) then
					max_inv = max_inv + (-alpha_loc)*maxmin_inv
					min_inv = min_inv - (-alpha_loc)*maxmin_inv
				!			end if
				!		end if
				!	end if

					if ((min_inv <= r_new(1)).and.(r_new(1) <= max_inv))    r_corrected(1) = r_new(1)
					if (r_new(1) < min_inv)                                 r_corrected(1) = min_inv
					if (max_inv < r_new(1))                                 r_corrected(1) = max_inv
					
					if ((min_inv <= r_new(2)).and.(r_new(2) <= max_inv))    r_corrected(2) = r_new(2)
					if (r_new(2) < min_inv)                                 r_corrected(2) = min_inv
					if (max_inv < r_new(2))                                 r_corrected(2) = max_inv               
					
					g_inv = ((Q_half - Q_old)/(0.5_dkind*this%time_step) + (v%pr(dim)%cells(i,j,k) - v_s%cells(i,j,k))*(q(2) - q(1))/cell_size(1))

					max_inv = max(q(1),Q_half,q(2)) + g_inv*this%time_step
					min_inv = min(q(1),Q_half,q(2)) + g_inv*this%time_step
					maxmin_inv = abs(max_inv - min_inv)
				
				!	if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
				!		if (abs(max_inv) > 1e-02) then
				!			if(abs(maxmin_inv) > 1.0e-02) then
					max_inv = max_inv + (-alpha_loc)*maxmin_inv
					min_inv = min_inv - (-alpha_loc)*maxmin_inv
				!			end if
				!		end if
				!	end if
	
					if ((min_inv <= q_new(1)).and.(q_new(1) <= max_inv))    q_corrected(1) = q_new(1)
					if (q_new(1) < min_inv)                                 q_corrected(1) = min_inv
					if (max_inv < q_new(1))                                 q_corrected(1) = max_inv
						
					if ((min_inv <= q_new(2)).and.(q_new(2) <= max_inv))	q_corrected(2) = q_new(2)
					if (q_new(2) < min_inv)									q_corrected(2) = min_inv
					if (max_inv < q_new(2))									q_corrected(2) = max_inv

					do dim2 = 1,dimensions
			
						g_inv = ((v_inv_half(dim2) - v_inv_old(dim2))/(0.5_dkind*this%time_step) + (v%pr(dim)%cells(i,j,k))*(v_inv(dim2,2) - v_inv(dim2,1))/cell_size(1))

						max_inv = max(v_inv(dim2,1),v_inv_half(dim2),v_inv(dim2,2)) + g_inv*this%time_step
						min_inv = min(v_inv(dim2,1),v_inv_half(dim2),v_inv(dim2,2)) + g_inv*this%time_step
						maxmin_inv = abs(max_inv - min_inv)
					
					!	if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
					!		if (abs(max_inv) > 1e-02) then
					!			if(abs(maxmin_inv) > 1.0e-02) then
						max_inv = max_inv + (-alpha_loc)*maxmin_inv
						min_inv = min_inv - (-alpha_loc)*maxmin_inv
					!			end if
					!		end if
					!	end if
						
						if ((min_inv <= v_inv_new(dim2,1)).and.(v_inv_new(dim2,1) <= max_inv))		v_inv_corrected(dim2,1) = v_inv_new(dim2,1)
						if (v_inv_new(dim2,1) < min_inv)											v_inv_corrected(dim2,1) = min_inv
						if (max_inv < v_inv_new(dim2,1))											v_inv_corrected(dim2,1) = max_inv
					
						if ((min_inv <= v_inv_new(dim2,2)).and.(v_inv_new(dim2,2) <= max_inv))		v_inv_corrected(dim2,2) = v_inv_new(dim2,2)
						if (v_inv_new(dim2,2) < min_inv)											v_inv_corrected(dim2,2) = min_inv
						if (max_inv < v_inv_new(dim2,2))											v_inv_corrected(dim2,2) = max_inv   											
		
					end do

					! ************* Lower edge *************
					! ************* Approximated velocity and speed of sound *******

#ifdef OMP					
					call omp_set_lock(lock(i,j,k))
					call omp_set_lock(lock(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))					
#endif					
					
					if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,1) ) then
						if	((.not.((abs(v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))	<	abs(	v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))))	.and.(	  v%pr(dim)%cells(i,j,k)	>		v_s%cells(i,j,k))))	&
						.and.(.not.((	 v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))	<			-v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))	.and.(abs(v%pr(dim)%cells(i,j,k))	< abs(	v_s%cells(i,j,k)))))) then 
						
							G_half_lower	= 1.0_dkind / (v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))*rho%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))
						
							v_f_approx		= 0.5_dkind*(v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))	+ v%pr(dim)%cells(i,j,k))
							v_s_f_approx	= 0.5_dkind*(v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))			+ v_s%cells(i,j,k))

							characteristic_speed(1) = v_f_approx + v_s_f_approx
							characteristic_speed(2) = v_f_approx - v_s_f_approx
							characteristic_speed(3) = v_f_approx
					
							if (( characteristic_speed(1) >= 0.0_dkind )	.and.&
								( characteristic_speed(2) < 0.0_dkind )		.and.&
								( characteristic_speed(3) >= 0.0_dkind )) then				

								p_f_new%cells(dim,i,j,k)			=	p_f_new%cells(dim,i,j,k)	-   q_corrected(1)	/ (G_half_lower + G_half)
								rho_f_new%cells(dim,i,j,k)			=	rho_f_new%cells(dim,i,j,k)	- ( q_corrected(1)	/ (G_half_lower + G_half)	)/ (v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))**2)
								
								do dim1 = 1,dimensions
									if ( dim == dim1 ) then 
										v_f_new%pr(dim1)%cells(dim,i,j,k)	=	v_f_new%pr(dim1)%cells(dim,i,j,k)	+ (G_half_lower	*	q_corrected(1))	/ (G_half_lower + G_half)
									end if
								end do
							end if		
			
							if (( characteristic_speed(1) >= 0.0_dkind ).and.&
								( characteristic_speed(2) < 0.0_dkind ).and.&
								( characteristic_speed(3) < 0.0_dkind )) then
						
								p_f_new%cells(dim,i,j,k)			=	p_f_new%cells(dim,i,j,k)	-   q_corrected(1)	/ (G_half_lower + G_half)
								rho_f_new%cells(dim,i,j,k)			=	rho_f_new%cells(dim,i,j,k)  - ( q_corrected(1)	/ (G_half_lower + G_half)	+	v_inv_corrected(dim,1))	/ (v_s%cells(i,j,k)**2)
							
								do dim1 = 1,dimensions
									if ( dim == dim1 ) then 
										v_f_new%pr(dim1)%cells(dim,i,j,k)	=	v_f_new%pr(dim1)%cells(dim,i,j,k)	+  (G_half_lower	*	q_corrected(1))	/ (G_half_lower + G_half)
									else
										v_f_new%pr(dim1)%cells(dim,i,j,k)	=	v_f_new%pr(dim1)%cells(dim,i,j,k)	+ v_inv_corrected(dim1,1)
									end if
								end do
								continue
							end if

							if (( characteristic_speed(1) >= 0.0_dkind ).and.&
								( characteristic_speed(2) >= 0.0_dkind ).and.&
								( characteristic_speed(3) >= 0.0_dkind )) then
							end if
					
							if (( characteristic_speed(1) < 0.0_dkind ).and.&
								( characteristic_speed(2) < 0.0_dkind ).and.&
								( characteristic_speed(3) < 0.0_dkind )) then
						
								p_f_new%cells(dim,i,j,k)			= p_f_new%cells(dim,i,j,k)	+ 0.5_dkind * (r_corrected(1) - q_corrected(1)) / G_half
						
								rho_f_new%cells(dim,i,j,k)			= rho_f_new%cells(dim,i,j,k) + (p_f_new%cells(dim,i,j,k) - v_inv_corrected(dim,1)) / (v_s%cells(i,j,k)**2)
						
								do dim1 = 1,dimensions
									if ( dim == dim1 ) then 
										v_f_new%pr(dim1)%cells(dim,i,j,k)	=	v_f_new%pr(dim1)%cells(dim,i,j,k) + 0.5_dkind * (r_corrected(1) + q_corrected(1))
									else
										v_f_new%pr(dim1)%cells(dim,i,j,k)	=	v_f_new%pr(dim1)%cells(dim,i,j,k) + v_inv_corrected(dim1,1)
									end if
								end do
							end if
						end if
					end if
						
					! ************* Higher edge *************
					! ************* Approximated velocity and speed of sound *******
					if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) ) then

						if ((	.not.((abs(	v%pr(dim)%cells(i,j,k))	<	abs(v_s%cells(i,j,k)))	.and.(		v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))		>		v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))))		&
						.and.(	.not.((		v%pr(dim)%cells(i,j,k)	<		-v_s%cells(i,j,k))	.and.(abs(	v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))	< abs(	v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))))))then
					
							G_half_higher	= 1.0_dkind / (v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*rho%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))
						
							v_f_approx		= 0.5_dkind*(v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+ v%pr(dim)%cells(i,j,k))
							v_s_f_approx	= 0.5_dkind*(v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			+ v_s%cells(i,j,k))
					
							characteristic_speed(1) = v_f_approx + v_s_f_approx
							characteristic_speed(2) = v_f_approx - v_s_f_approx
							characteristic_speed(3) = v_f_approx
					
							if (( characteristic_speed(1) >= 0.0_dkind )	.and.&
								( characteristic_speed(2) < 0.0_dkind )		.and.&
								( characteristic_speed(3) >= 0.0_dkind )) then				
				
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+	r_corrected(2)	/ (G_half_higher + G_half)
								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + (	r_corrected(2)	/ (G_half_higher + G_half) - v_inv_corrected(dim,2)	) / (v_s%cells(i,j,k)**2)
								
								do dim1 = 1,dimensions
									if ( dim == dim1 ) then 
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + (G_half_higher	*	r_corrected(2))	/ (G_half_higher + G_half)
									else
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + v_inv_corrected(dim1,2)
										if ( characteristic_speed(3) == 0 ) then
											v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) =v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + v_f(dim1,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
										end if
									end if
								end do
							end if		
			
							if (( characteristic_speed(1) >= 0.0_dkind ).and.&
								( characteristic_speed(2) < 0.0_dkind ).and.&
								( characteristic_speed(3) < 0.0_dkind )) then
						
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+	r_corrected(2)	/ (G_half_higher + G_half)
								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+	r_corrected(2)	/ (G_half_higher + G_half)	/ (v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))**2)
								
								do dim1 = 1,dimensions
									if ( dim == dim1 ) then 
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + G_half_higher	*	r_corrected(2)	/ (G_half_higher + G_half)
									end if
								end do
							end if

							if (( characteristic_speed(1) >= 0.0_dkind ).and.&
								( characteristic_speed(2) >= 0.0_dkind ).and.&
								( characteristic_speed(3) >= 0.0_dkind )) then
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + 0.5_dkind * (r_corrected(2) - q_corrected(2)) / G_half

								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + (p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)

								do dim1 = 1,dimensions
									if ( dim == dim1 ) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + 0.5_dkind * (r_corrected(2) + q_corrected(2))
									else
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + v_inv_corrected(dim1,2)
										if ( characteristic_speed(3) == 0 ) then
											v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + v_f(dim1,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
										end if
									end if
								end do
							end if
					
							if (( characteristic_speed(1) < 0.0_dkind ).and.&
								( characteristic_speed(2) < 0.0_dkind ).and.&
								( characteristic_speed(3) < 0.0_dkind )) then
							end if
							
						end if
					end if

					
					!**************************** Sound points *****************************
					!**************************** Lower edge *******************************
					if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,1) ) then

						v_f_approx		= 0.5_dkind*(v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))	+ v%pr(dim)%cells(i,j,k))
						v_s_f_approx	= 0.5_dkind*(v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))			+ v_s%cells(i,j,k))

						characteristic_speed(1) = v_f_approx + v_s_f_approx
						characteristic_speed(2) = v_f_approx - v_s_f_approx
						characteristic_speed(3) = v_f_approx

						if (((abs(v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))	<	abs(v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))) &
						.and.(	  v%pr(dim)%cells(i,j,k)	>	v_s%cells(i,j,k))) )then
							if(use_riemann_mod == '1') then
								call solve_riemann_problem5(&
										p_f_new%cells(dim, i, j, k), v_f_new%pr(dim)%cells(dim, i, j, k), rho_f_new%cells(dim, i, j, k), &
										p%cells(i - I_m(dim, 1), j - I_m(dim, 2), k - I_m(dim, 3)), v%pr(dim)%cells(i - I_m(dim, 1), j - I_m(dim, 2), k - I_m(dim, 3)), rho%cells(i - I_m(dim, 1), j - I_m(dim, 2), k - I_m(dim, 3)), &
										p%cells(i, j, k), v%pr(dim)%cells(i, j, k), rho%cells(i, j, k), &
										this%time_step, gamma%cells(i - I_m(dim, 1), j - I_m(dim, 2), k - I_m(dim, 3)), gamma%cells(i, j, k)&
										)
							else
								if (characteristic_speed(3) < 0.0_dkind) then
									rho_f_new%cells(dim,i,j,k) = rho_f_new%cells(dim,i,j,k) - v_inv_corrected(dim,1) / (v_s%cells(i,j,k)**2)
								end if
							end if
						end if
						if (((	 v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))	 <	  -v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)))	&
						.and.	(abs(v%pr(dim)%cells(i,j,k)) < abs(v_s%cells(i,j,k)))))then
							if(use_riemann_mod == '1') then
								! noop
							else
								v_f_new%pr(dim)%cells(dim,i,j,k)	=	0.5_dkind*(v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))/v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)) + v%pr(dim)%cells(i,j,k)/v_s%cells(i,j,k)) &
										*0.5_dkind*(v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3)) + v_s%cells(i,j,k))

								p_f_new%cells(dim,i,j,k)			= (v_f_new%pr(dim)%cells(dim,i,j,k) - q_corrected(1))/G_half

								if( characteristic_speed(3) >= 0.0_dkind ) then
									rho_f_new%cells(dim,i,j,k) = rho_f_new%cells(dim,i,j,k) + (p_f_new%cells(dim,i,j,k)) / (v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))**2)
								else
									rho_f_new%cells(dim,i,j,k) = (p_f_new%cells(dim,i,j,k) - v_inv_corrected(dim,1)) / (v_s%cells(i,j,k)**2)
								end if
							end if
						end if
					end if

					!**************************** Higher edge *******************************

					if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) ) then
						v_f_approx		= 0.5_dkind*(v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+ v%pr(dim)%cells(i,j,k))
						v_s_f_approx	= 0.5_dkind*(v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			+ v_s%cells(i,j,k))

						characteristic_speed(1) = v_f_approx + v_s_f_approx
						characteristic_speed(2) = v_f_approx - v_s_f_approx
						characteristic_speed(3) = v_f_approx

						if (((abs(v%pr(dim)%cells(i,j,k))	<	abs(v_s%cells(i,j,k))) &
						.and.(	  v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	>	v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))) )then
							if(use_riemann_mod == '1') then
								call solve_riemann_problem5(&
										p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)),&
										p%cells(i,j,k), v%pr(dim)%cells(i,j,k), rho%cells(i,j,k),&
										p%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), rho%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)),&
										this%time_step, gamma%cells(i, j, k), gamma%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))&
										)
							else
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + 0.5_dkind * (r_corrected(2) - q_corrected(2)) / G_half

								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + (p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)

								do dim1 = 1,dimensions
									if ( dim == dim1 ) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + 0.5_dkind * (r_corrected(2) + q_corrected(2))
									else
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + v_inv_corrected(dim1,2)
										if ( characteristic_speed(3) == 0 ) then
											v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) + v_f(dim1,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
										end if
									end if
								end do
							end if
						end if

						if (((	 v%pr(dim)%cells(i,j,k)	 <	  -v_s%cells(i,j,k))	&
						.and.	(abs(v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))) < abs(v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))))))then
							if(use_riemann_mod == '1') then
								! noop
							else
								if( characteristic_speed(3) >= 0.0_dkind ) then
									rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) =  rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2) / (v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))**2)
								end if
							end if
						end if

					end if
#ifdef OMP						
					call omp_unset_lock(lock(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))
					call omp_unset_lock(lock(i,j,k))	
#endif

					!**************************** Boundary conditions *****************************
					if (( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,1) ) .and. &
						( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) )) then
						do plus = 1,2
							sign			= (-1)**plus
							bound_number	= bc%bc_markers(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))
							if( bound_number /= 0 ) then

								v_f_approx		= 0.5_dkind * (v%pr(dim)%cells(i,j,k)	+ v%pr(dim)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)))
								v_s_f_approx	= 0.5_dkind * (v_s%cells(i,j,k)			+ v_s%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)))								
		
								characteristic_speed(1) = v_f_approx + v_s_f_approx
								characteristic_speed(2) = v_f_approx - v_s_f_approx
								characteristic_speed(3) = v_f_approx		
									
								call this%apply_boundary_conditions_flow(dim, i,j,k, characteristic_speed, q_corrected, r_corrected, v_inv_corrected, G_half)
								
							end if
						end do
					end if
				end if
			end do
			end do
			end do
			!$omp end do
		
		end do
		!$omp end parallel		
		
        ! ************************************************  		
		
		call this%mpi_support%exchange_flow_scalar_field(rho_f_new)
		call this%mpi_support%exchange_flow_scalar_field(p_f_new)

		!$omp parallel default(none)  private(i,j,k,dim,loop,spec,Y_inv,Y_inv_half,Y_inv_new,Y_inv_old,g_inv,max_inv,min_inv,maxmin_inv,alpha_loc,Y_inv_corrected,v_f_approx_lower,v_f_approx_higher,spec_summ,bound_number,diss_r,diss_l) , &
		!$omp& firstprivate(this) , &
		!$omp& shared(cons_utter_loop,cons_inner_loop,dimensions,species_number,bc,Y,Y_f,Y_f_new,Y_prod,v,v_f_new,v_s,v_s_f,p,p_f,p_f_new,rho,rho_f,rho_f_new,gamma,E_f_prod,Max_v_s,Min_v_s,diss,alpha,cell_size,lock)		

		do dim = 1,dimensions

			! Avoid looping in transverse direction in ghost cells

			loop(3,1) = cons_utter_loop(3,1)*I_m(dim,3) + cons_inner_loop(3,1)*(1 - I_m(dim,3))
			loop(3,2) = cons_utter_loop(3,2)*I_m(dim,3) + cons_inner_loop(3,2)*(1 - I_m(dim,3))

			loop(2,1) = cons_utter_loop(2,1)*I_m(dim,2) + cons_inner_loop(2,1)*(1 - I_m(dim,2))
			loop(2,2) = cons_utter_loop(2,2)*I_m(dim,2) + cons_inner_loop(2,2)*(1 - I_m(dim,2))	

			loop(1,1) = cons_utter_loop(1,1)*I_m(dim,1) + cons_inner_loop(1,1)*(1 - I_m(dim,1))
			loop(1,2) = cons_utter_loop(1,2)*I_m(dim,1) + cons_inner_loop(1,2)*(1 - I_m(dim,1))						

			!$omp do collapse(3) schedule(guided)	
			do k = loop(3,1),loop(3,2)
			do j = loop(2,1),loop(2,2)
			do i = loop(1,1),loop(1,2)		
			
				if(bc%bc_markers(i,j,k) == 0) then
	
					do spec = 1,species_number
						y_inv(spec,1)		= Y_f(spec,dim,i,j,k)									* rho_f(dim,i,j,k)										- Y%pr(spec)%cells(i,j,k) / v_s%cells(i,j,k)**2 * p_f(dim,i,j,k)							
						y_inv(spec,2)		= Y_f(spec,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	* rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	- Y%pr(spec)%cells(i,j,k) / v_s%cells(i,j,k)**2 * p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
						Y_inv_half(spec)	= Y%pr(spec)%cells(i,j,k)								* rho%cells(i,j,k)										- Y%pr(spec)%cells(i,j,k) / v_s%cells(i,j,k)**2 * p%cells(i,j,k)		
						Y_inv_old(spec)		= Y_old(spec,i,j,k)										* rho_old(i,j,k)										- Y%pr(spec)%cells(i,j,k) / v_s%cells(i,j,k)**2 * p_old(i,j,k)	
					end do	
					
					diss_l = 0.0_dkind
					diss_r = 0.0_dkind

					!if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,1) ) then
					!	if (( v_s_f(dim,i,j,k) > (max(v_s%cells(i,j,k),v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))) + 300.0_dkind))	&
					!	.or.( v_s_f(dim,i,j,k) < (min(v_s%cells(i,j,k),v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))) - 300.0_dkind))) then
					!		diss_l = diss

					!	end if
					!end if

					!if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) ) then
					!	if (( v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) > (max(v_s%cells(i,j,k),v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))) + 300.0_dkind))	&
					!	.or.( v_s_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) < (min(v_s%cells(i,j,k),v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))) - 300.0_dkind))) then
					!		diss_r = diss
					!	end if
					!end if

					do spec = 1,species_number
						y_inv_new(spec,1)	= (2.0_dkind*Y_inv_half(spec) - (1.0_dkind-diss_l)*y_inv(spec,2))/(1.0_dkind+diss_l)
						y_inv_new(spec,2)	= (2.0_dkind*Y_inv_half(spec) - (1.0_dkind-diss_r)*y_inv(spec,1))/(1.0_dkind+diss_r)
					end do	
					
					do spec = 1,species_number
						g_inv =  0.0_dkind
						!do dim1 = 1,dimensions
						!	if ( dim1 /= dim ) then
						!		g_inv = g_inv - this%time_step * v%pr(dim1)%cells(i,j,k) * (rho_f(dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3)) * Y_f(spec,dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))  - Y_f(spec,dim1,i,j,k) * rho_f(dim1,i,j,k))/cell_size(1)
						!		g_inv = g_inv + this%time_step * v%pr(dim1)%cells(i,j,k) * Y%pr(spec)%cells(i,j,k) 	* (p_f(dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))  - p_f(dim1,i,j,k))/cell_size(1) / v_s%cells(i,j,k)  / v_s%cells(i,j,k)
						!	end if
						!end do
						
						g_inv = ((Y_inv_half(spec) - Y_inv_old(spec))/(0.5_dkind*this%time_step) + (v%pr(dim)%cells(i,j,k))*(y_inv(spec,2) - y_inv(spec,1))/cell_size(1))
						
						alpha_loc = alpha
						
						max_inv	= max(y_inv(spec,1),Y_inv_half(spec),y_inv(spec,2)) +  g_inv*this%time_step
						min_inv	= min(y_inv(spec,1),Y_inv_half(spec),y_inv(spec,2)) +  g_inv*this%time_step

						maxmin_inv = abs(max_inv - min_inv)
						
						max_inv = max_inv + (-alpha_loc)*maxmin_inv
						min_inv = min_inv - (-alpha_loc)*maxmin_inv
					
					!	if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
					!		if (abs(max_inv) > 1e-02) then
					!			if(abs(maxmin_inv) > 1.0e-02) then
					!				max_inv = max_inv + (-0.005_dkind)*maxmin_inv
					!				min_inv = min_inv - (-0.005_dkind)*maxmin_inv
					!			end if
					!		end if
					!	end if

						if ((min_inv <= y_inv_new(spec,1)).and.(y_inv_new(spec,1) <= max_inv))		y_inv_corrected(spec,1) = y_inv_new(spec,1)
						if (y_inv_new(spec,1) < min_inv)											y_inv_corrected(spec,1) = min_inv
						if (max_inv < y_inv_new(spec,1))											y_inv_corrected(spec,1) = max_inv
					
						if ((min_inv <= y_inv_new(spec,2)).and.(y_inv_new(spec,2) <= max_inv))		y_inv_corrected(spec,2) = y_inv_new(spec,2)
						if (y_inv_new(spec,2) < min_inv)											y_inv_corrected(spec,2) = min_inv
						if (max_inv < y_inv_new(spec,2))											y_inv_corrected(spec,2) = max_inv
						
					end do					
					
#ifdef OMP					
					call omp_set_lock(lock(i,j,k))
					call omp_set_lock(lock(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))	
#endif

					!# ��������� ������� �� Y �������� ������ � ������� ���������� �����������, ����� �������� �� �������� ��������� �� �����
					do spec = 1,species_number
						if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,1) ) then
							bound_number	= bc%bc_markers(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))
							if(bound_number == 0) then	
								v_f_approx_lower		= 0.5_dkind*(v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))	+ v%pr(dim)%cells(i,j,k)) !v_f_new%pr(dim)%cells(dim,i,j,k) !0.5_dkind*(v%pr(dim)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))	+ v%pr(dim)%cells(i,j,k)) !- v_f(dim,dim,i,j,k)
								if (v_f_approx_lower < 0.0_dkind) then
									Y_f_new%pr(spec)%cells(dim,i,j,k) =  (y_inv_corrected(spec,1) + Y%pr(spec)%cells(i,j,k) * p_f(dim,i,j,k)  / v_s%cells(i,j,k)**2 )  / rho_f(dim,i,j,k) !y_inv_corrected(spec,1) !
								end if	
							end if
						end if

						if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,2) ) then
							bound_number	= bc%bc_markers(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
							if(bound_number == 0) then
								v_f_approx_higher		= 0.5_dkind*(v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+ v%pr(dim)%cells(i,j,k)) !v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) !0.5_dkind*(v%pr(dim)%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+ v%pr(dim)%cells(i,j,k)) !- v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
								if (v_f_approx_higher >= 0.0_dkind) then
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = (y_inv_corrected(spec,2) + Y%pr(spec)%cells(i,j,k) * p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))  / v_s%cells(i,j,k)**2 ) / rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) !y_inv_corrected(spec,2) !
								end if
							end if
						end if
					end do
					
#ifdef OMP						
					call omp_unset_lock(lock(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))
					call omp_unset_lock(lock(i,j,k))	
#endif
				end if
			end do
			end do
			end do
		!$omp end do
			
		!$omp do collapse(3) schedule(guided)	
			do k = loop(3,1),loop(3,2)
			do j = loop(2,1),loop(2,2)
			do i = loop(1,1),loop(1,2)	
				if(bc%bc_markers(i,j,k) == 0) then
					if ( (I_m(dim,1)*i + I_m(dim,2)*j + I_m(dim,3)*k) /= cons_utter_loop(dim,1) ) 	then
						spec_summ = 0.0_dkind
						do spec = 1,species_number
							spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind)
						end do
						
						!if (spec_summ < 0) then
						!	print *, 'Flow species exception ', dim, i,j,k
						!	stop
						!end if
						
						do spec = 1,species_number
							Y_f_new%pr(spec)%cells(dim,i,j,k) = max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind) / spec_summ
						end do
					end if
				end if
			end do
			end do
			end do
			!$omp end do nowait	

		end do
	
		!$omp end parallel

		! ******************* Eqn of state ***************
		call this%state_eq%apply_state_equation_flow_variables() 
		
        ! ************************************************  

		call this%mpi_support%exchange_flow_scalar_field(e_i_f_new)
		call this%mpi_support%exchange_flow_scalar_field(E_f_f_new)	
		call this%mpi_support%exchange_flow_scalar_field(v_s_f_new)
		call this%mpi_support%exchange_flow_vector_field(v_f_new)		
		call this%mpi_support%exchange_flow_vector_field(Y_f_new)

        ! *********** Conservative variables calculation ***************
		
		!$omp parallel default(none)  private(i,j,k,dim,dim1,spec,spec_summ,mean_higher,mean_lower) , &
		!$omp& firstprivate(this) , &
		!$omp& shared(cons_inner_loop,bc,dimensions,species_number,p,p_f,p_f_new,rho,rho_f,rho_f_new,rho_prod,rho_old,v,v_f,v_f_new,v_prod,v_old,Y,Y_f,Y_f_new,Y_prod,Y_old,E_f,E_f_f,E_f_f_new,E_f_prod,E_F_old,mesh,cell_size,nu,coordinate_system)
		!$omp do collapse(3) schedule(guided)			
		do k = cons_inner_loop(3,1),cons_inner_loop(3,2)
		do j = cons_inner_loop(2,1),cons_inner_loop(2,2)
		do i = cons_inner_loop(1,1),cons_inner_loop(1,2)
  			
			if (bc%bc_markers(i,j,k) == 0) then	
			
				rho%cells(i,j,k)		= 0.0_dkind
				do dim = 1,dimensions
					mean_higher	= 0.5_dkind*(rho_f(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)) *v_f(dim,dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)) + rho_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))  *v_f_new%pr(dim)%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))) 
					mean_lower	= 0.5_dkind*(rho_f(dim,i,j,k)   *v_f(dim,dim,i,j,k) +   rho_f_new%cells(dim,i,j,k)    *v_f_new%pr(dim)%cells(dim,i,j,k))
				
					rho%cells(i,j,k)	=	rho%cells(i,j,k)	- (	mean_higher - mean_lower )	/cell_size(1)
					
					if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
						rho%cells(i,j,k)	=	rho%cells(i,j,k) - 1.0_dkind * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																			 * 0.5_dkind * (rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	rho_f(dim,i,j,k)*v_f(dim,dim,i,j,k))	&
																			 * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1)))
																			 
						rho%cells(i,j,k)	=	rho%cells(i,j,k) - 1.0_dkind * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																			 * 0.5_dkind * (rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	 rho_f_new%cells(dim,i,j,k)*v_f_new%pr(dim)%cells(dim,i,j,k))	&
																			 * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1)))
					end if						
				end do
				rho%cells(i,j,k)		=	rho_old(i,j,k) + this%time_step*rho%cells(i,j,k)
	   
				spec_summ = 0.0_dkind
				do spec = 1,species_number
					Y%pr(spec)%cells(i,j,k)		= 0.0_dkind
					do	dim = 1,dimensions
						mean_higher	= 0.5_dkind*( rho_f(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)) * y_f(spec,dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)) *v_f(dim,dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))  &
												+ rho_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))  * y_f_new%pr(spec)%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)) *v_f_new%pr(dim)%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)))
												
						mean_lower	= 0.5_dkind*( rho_f(dim,i,j,k)   *y_f(spec,dim,i,j,k)   *v_f(dim,dim,i,j,k)   + rho_f_new%cells(dim,i,j,k)    * y_f_new%pr(spec)%cells(dim,i,j,k)   *v_f_new%pr(dim)%cells(dim,i,j,k))
						
						Y%pr(spec)%cells(i,j,k)	=  Y%pr(spec)%cells(i,j,k)	-	(mean_higher - mean_lower ) /cell_size(1)
						
						if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
							Y%pr(spec)%cells(i,j,k)	=	Y%pr(spec)%cells(i,j,k) - 1.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																							 * 0.5_dkind * (rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*Y_f(spec,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	rho_f(dim,i,j,k)*Y_f(spec,dim,i,j,k)*v_f(dim,dim,i,j,k))	&
																							 * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 	
							Y%pr(spec)%cells(i,j,k)	=	Y%pr(spec)%cells(i,j,k) - 1.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																							 * 0.5_dkind * (rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	rho_f_new%cells(dim,i,j,k)*y_f_new%pr(spec)%cells(dim,i,j,k)*v_f_new%pr(dim)%cells(dim,i,j,k))	&
																							 * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 																	 
						end if							
						
					end do
					
					Y%pr(spec)%cells(i,j,k)		=	rho_old(i,j,k) * Y_old(spec,i,j,k) + this%time_step * Y%pr(spec)%cells(i,j,k)
					Y%pr(spec)%cells(i,j,k)		=	Y%pr(spec)%cells(i,j,k)	/ rho%cells(i,j,k)
					
					spec_summ = spec_summ + max(Y%pr(spec)%cells(i,j,k), 0.0_dkind)
				end do
				
				!if (spec_summ < 0) then
				!	print *, 'Conservative species exception ', i,j,k
				!	stop
				!end if
				
				do spec = 1,species_number
					Y%pr(spec)%cells(i,j,k) = max(Y%pr(spec)%cells(i,j,k), 0.0_dkind) / spec_summ 
				end do
    
    
				do dim = 1,dimensions
					v%pr(dim)%cells(i,j,k)		=	0.0_dkind 
					do dim1 = 1,dimensions
						mean_higher	= 0.5_dkind*(		rho_f(dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3)) *v_f(dim,dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3))*v_f(dim1,dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3))  &
													+	rho_f_new%cells(dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3))  *v_f_new%pr(dim)%cells(dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3)) *v_f_new%pr(dim1)%cells(dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3))  )
						mean_lower	= 0.5_dkind*(		rho_f(dim1,i,j,k) *v_f(dim,dim1,i,j,k)*v_f(dim1,dim1,i,j,k)  &
													+	rho_f_new%cells(dim1,i,j,k)  *v_f_new%pr(dim)%cells(dim1,i,j,k) *v_f_new%pr(dim1)%cells(dim1,i,j,k)  )
													
						v%pr(dim)%cells(i,j,k)	=  v%pr(dim)%cells(i,j,k)	-	(	mean_higher - mean_lower)	/cell_size(1)
						
						if (((coordinate_system == 'cylindrical').and.(dim == 1)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
							v%pr(dim)%cells(i,j,k)	=	v%pr(dim)%cells(i,j,k) - 1.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																							* 0.5_dkind * (rho_f(dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))*v_f(dim,dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3))*v_f(dim1,dim1,i+I_m(dim1,1),j+I_m(dim1,2),k+I_m(dim1,3)) +	rho_f(dim1,i,j,k)*v_f(dim,dim1,i,j,k)*v_f(dim1,dim1,i,j,k))	&
																							* ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 
							v%pr(dim)%cells(i,j,k)	=	v%pr(dim)%cells(i,j,k) - 1.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																							* 0.5_dkind * (rho_f_new%cells(dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3))  *v_f_new%pr(dim)%cells(dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3)) *v_f_new%pr(dim1)%cells(dim1,i+i_m(dim1,1),j+i_m(dim1,2),k+i_m(dim1,3)) + rho_f_new%cells(dim1,i,j,k)  *v_f_new%pr(dim)%cells(dim1,i,j,k) *v_f_new%pr(dim1)%cells(dim1,i,j,k))	&
																							* ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 																
						end if							
					end do
	   
					mean_higher	= 0.5_dkind*(p_f(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))	+	p_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)) )
					mean_lower	= 0.5_dkind*(p_f(dim,i,j,k) 									+	p_f_new%cells(dim,i,j,k) )
													
					v%pr(dim)%cells(i,j,k)	=  v%pr(dim)%cells(i,j,k)	-	(	mean_higher - mean_lower)	/cell_size(1)
					
					v%pr(dim)%cells(i,j,k)	= rho_old(i,j,k)*v_old(dim,i,j,k) +  this%time_step * v%pr(dim)%cells(i,j,k)
					v%pr(dim)%cells(i,j,k)	= v%pr(dim)%cells(i,j,k) / rho%cells(i,j,k) 
				end do	
	   
				e_f%cells(i,j,k)		=	0.0_dkind  
				do dim = 1,dimensions
					mean_higher	= 0.5_dkind*(		(rho_f(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))*E_f_f(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))	+	p_f(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)))*v_f(dim,dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))	&
												+	(rho_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))*E_f_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))	+	p_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)))*v_f_new%pr(dim)%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)))
												
					mean_lower	= 0.5_dkind*(		(rho_f(dim,i,j,k)*E_f_f(dim,i,j,k)						+	p_f(dim,i,j,k))*v_f(dim,dim,i,j,k)	&
												+	(rho_f_new%cells(dim,i,j,k)*E_f_f_new%cells(dim,i,j,k)	+	p_f_new%cells(dim,i,j,k))*v_f_new%pr(dim)%cells(dim,i,j,k))	
				
					E_f%cells(i,j,k)			= 	E_f%cells(i,j,k)		-	(	mean_higher - mean_lower)	/cell_size(1)
					
					if (((coordinate_system == 'cylindrical').and.(dim == 2)).or.((coordinate_system == 'spherical').and.(dim == 1))) then
						E_f%cells(i,j,k)	=	E_f%cells(i,j,k) - 1.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																			  * 0.5_dkind * ((rho_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))*E_f_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	+	p_f(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))*v_f(dim,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) +	(rho_f(dim,i,j,k)*E_f_f(dim,i,j,k)	+	p_f(dim,i,j,k))*v_f(dim,dim,i,j,k))	&
																			  * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 	
						E_f%cells(i,j,k)	=	E_f%cells(i,j,k) - 1.0_dkind  * (nu - 1.0_dkind)/( (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) + (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind))		&
																			  * 0.5_dkind * ((rho_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))*E_f_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3))	+	p_f_new%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)))*v_f_new%pr(dim)%cells(dim,i+i_m(dim,1),j+i_m(dim,2),k+i_m(dim,3)) +	(rho_f_new%cells(dim,i,j,k)*E_f_f_new%cells(dim,i,j,k)	+	p_f_new%cells(dim,i,j,k))*v_f_new%pr(dim)%cells(dim,i,j,k))	&
																			  * ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))**(nu - 1.0_dkind) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))**(nu - 1.0_dkind)) / ((mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) - (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))) 						
					end if					
				end do	
				E_f%cells(i,j,k) = rho_old(i,j,k) * E_f_old(i,j,k) + this%time_step * E_f%cells(i,j,k)
				E_f%cells(i,j,k) = E_f%cells(i,j,k) /rho%cells(i,j,k)
	
			end if
        end do
		end do
		end do
        ! **************************************************************
		!$omp end do nowait		
		!$omp end parallel

		call this%mpi_support%exchange_conservative_vector_field(v)	

		call this%apply_boundary_conditions_main()

		if (this%heat_trans_flag)	call this%heat_trans_solver%solve_heat_transfer(this%time_step)
		if (this%diffusion_flag)	call this%diff_solver%solve_diffusion(this%time_step)
		if (this%viscosity_flag)	call this%viscosity_solver%solve_viscosity(this%time_step)
		if (this%reactive_flag)		call this%chem_kin_solver%solve_chemical_kinetics(this%time_step)

		E_f_prod	= 0.0_dkind
		rho_prod	= 0.0_dkind
		Y_prod		= 0.0_dkind
		v_prod		= 0.0_dkind	
		
		!$omp parallel default(none)  private(i,j,k,dim,spec,spec_summ) , &
		!$omp& firstprivate(this) , &
		!$omp& shared(cons_inner_loop,bc,mesh,rho,v,Y,E_f,E_f_prod,E_f_prod_chem,E_f_prod_heat,E_f_prod_visc,E_f_prod_diff,Y_prod,Y_prod_chem,Y_prod_diff,v_prod,v_prod_visc,species_number,dimensions,energy_source,energy_output_rho,energy_output,energy_output_flag,energy_output_time,energy_output_radii,cell_size,coordinate_system)
		!$omp do collapse(3) schedule(guided)		
		do k = cons_inner_loop(3,1),cons_inner_loop(3,2)
		do j = cons_inner_loop(2,1),cons_inner_loop(2,2)
		do i = cons_inner_loop(1,1),cons_inner_loop(1,2)
			
			if(bc%bc_markers(i,j,k) == 0) then	
				
				if (this%reactive_flag)	then
					E_f_prod(i,j,k) = E_f_prod(i,j,k) + E_f_prod_chem%cells(i,j,k) * this%time_step
					do spec = 1,species_number
						Y_prod(spec,i,j,k)	= Y_prod(spec,i,j,k)	+ Y_prod_chem%pr(spec)%cells(i,j,k) * this%time_step
					end do		
				end if

				if (this%heat_trans_flag)	then
					E_f_prod(i,j,k) = E_f_prod(i,j,k) + E_f_prod_heat%cells(i,j,k) * this%time_step
				end if

				if (this%diffusion_flag)	then
					E_f_prod(i,j,k) = E_f_prod(i,j,k) + E_f_prod_diff%cells(i,j,k) * this%time_step
					do spec = 1, species_number
						Y_prod(spec,i,j,k)	= Y_prod(spec,i,j,k)	+ Y_prod_diff%pr(spec)%cells(i,j,k) * this%time_step
					end do
				end if

				if (this%viscosity_flag)	then
					E_f_prod(i,j,k) = E_f_prod(i,j,k) + E_f_prod_visc%cells(i,j,k) * this%time_step
					do dim = 1, dimensions
						v_prod(dim,i,j,k)	= v_prod(dim,i,j,k) + v_prod_visc%pr(dim)%cells(i,j,k) * this%time_step
				!		v_prod(dim,i,j,k)	= v_prod(dim,i,j,k) + g(dim) * (rho%cells(1,1,1) - rho%cells(i,j,k)) * this%time_step
					end do
				end if		
				
				! ************************* Energy release ******************
				if (energy_output_flag == 1) then 
					if(this%time <= energy_output_time) then
						if(mesh%mesh(1,i,j,k) <= mesh%mesh(1,1,j,k) + energy_output_radii) then
							E_f_prod(i,j,k)			= E_f_prod(i,j,k)	+ energy_source * 1.0e+10 * this%time_step *  rho%cells(i,j,k) !* cell_size(1) ! * 4.0_dkind * Pi * mesh%mesh(1,i,j,k) * mesh%mesh(1,i,j,k)
							energy_output_rho		= energy_output_rho	+ energy_source * 1.0e+10 * this%time_step *  rho%cells(i,j,k) * cell_size(1) * 4.0_dkind * Pi  ! * mesh%mesh(1,i,j,k) * mesh%mesh(1,i,j,k)
							energy_output			= energy_output		+ energy_source * 1.0e+10 * this%time_step
						end if
					else	
						energy_output_flag = 2
					end if
				else
					if (energy_output_flag == 2) then
						print *, ' Energy input	: ', energy_output_rho
						print *, ' Time	: ', this%time
						print *, 'r_0 : ', mesh%mesh(1,1,j,k), ' r_f : ', energy_output_radii/cell_size(1)
						stop
						energy_output_flag = 0
					end if				
				end if
				! ***********************************************************				
				
				E_f%cells(i,j,k) = E_f%cells(i,j,k) + E_f_prod(i,j,k)/rho%cells(i,j,k)
				
				spec_summ = 0.0_dkind
				do spec = 1, species_number
					Y%pr(spec)%cells(i,j,k) = Y%pr(spec)%cells(i,j,k) + Y_prod(spec,i,j,k)/rho%cells(i,j,k)
					spec_summ = spec_summ + Y%pr(spec)%cells(i,j,k)
				end do		
				do spec = 1,species_number
					Y%pr(spec)%cells(i,j,k) = max(Y%pr(spec)%cells(i,j,k), 0.0_dkind) / spec_summ 
				end do				
				
				do dim = 1, dimensions
					v%pr(dim)%cells(i,j,k)	= v%pr(dim)%cells(i,j,k) + v_prod(dim,i,j,k) /rho%cells(i,j,k)
				end do	
				
			end if	
		end do	
		end do
		end do
		!$omp end do nowait
		!$omp end parallel			
		
		call this%state_eq%apply_state_equation() 		
		
		!$omp parallel default(none)  private(i,j,k,dim,spec) , &
		!$omp& firstprivate(this) , &
		!$omp& shared(flow_utter_loop,Y_f,v_f,p_f,rho_f,E_f_f,Y_f_new,v_f_new,p_f_new,rho_f_new,E_f_f_new,v_s_f,v_s_f_new,species_number,dimensions)
		do dim = 1,dimensions
			!$omp do collapse(3) schedule(static)			
			do k = flow_utter_loop(3,1),flow_utter_loop(3,2)
			do j = flow_utter_loop(2,1),flow_utter_loop(2,2)
			do i = flow_utter_loop(1,1),flow_utter_loop(1,2)		
		
				!spec_summ = 0.0_dkind
				do spec = 1,species_number
					Y_f(spec,dim,i,j,k)	= Y_f_new%pr(spec)%cells(dim,i,j,k)		
				!	spec_summ = spec_summ + Y_f(spec,dim,i,j,k)
				end do

				!if(spec_summ == 0.0_dkind) then
				!	print *, 'Spec summ', i,j,k,dim
				!end if

				!do spec = 1,species_number
				!	Y_f(spec,dim,i,j,k) = max(Y_f(spec,dim,i,j,k), 0.0_dkind) / spec_summ 
				!end do		

				do dim1 = 1,dimensions
					v_f(dim1,dim,i,j,k)		= v_f_new%pr(dim1)%cells(dim,i,j,k)
				end do
	
				p_f(dim,i,j,k)	    = p_f_new%cells(dim,i,j,k)	
				rho_f(dim,i,j,k)	= rho_f_new%cells(dim,i,j,k)	
				E_f_f(dim,i,j,k)	= E_f_f_new%cells(dim,i,j,k)
				v_s_f(dim,i,j,k)	= v_s_f_new%cells(dim,i,j,k)

			end do
			end do
			end do
			! **************************************************************
			!$omp end do nowait	
		end do
		!$omp end parallel
		
	!	call this%state_eq%check_conservation_laws()
		
		end associate

	end subroutine

	subroutine apply_boundary_conditions_flow(this, dim,i,j,k, characteristic_speed, q_corrected, r_corrected, v_inv_corrected, G_half)

		class(cabaret_solver)		,intent(inout)		:: this
		integer						,intent(in)			:: i, j, k, dim
		real(dkind)	,dimension(3)	,intent(in)			:: characteristic_speed
		real(dkind)	,dimension(2)	,intent(in)			:: q_corrected, r_corrected
		real(dkind)	,dimension(:,:)	,intent(in)			:: v_inv_corrected
		real(dkind)					,intent(in)			:: G_half
		
		real(dkind)				:: r_inf, q_inf, s_inf, G_half_inf

		real(dkind)				:: spec_summ

		real(dkind)	,dimension(3)	:: cell_size
		character(len=20)		:: boundary_type_name
		integer					:: dimensions, species_number
		character(len=20)		:: coordinate_system
		integer					:: sign, bound_number
		integer 				:: plus, dim1, spec	

		associate(  v_s				=> this%v_s%s_ptr			, &
					rho				=> this%rho%s_ptr			, &
					p				=> this%p%s_ptr				, &
					E_f				=> this%E_f%s_ptr			, &
					v_f				=> this%v_f					, &
					v				=> this%v%v_ptr				, &
					Y				=> this%Y%v_ptr				, &
					p_f_new			=> this%p_f_new%s_ptr		, &	
					rho_f_new		=> this%rho_f_new%s_ptr		, &
					E_f_f_new		=> this%E_f_f_new%s_ptr		, &
					v_f_new			=> this%v_f_new%v_ptr		, &
					bc				=> this%boundary%bc_ptr		, &
					mesh			=> this%mesh%mesh_ptr)

		dimensions		= this%domain%get_domain_dimensions()
		species_number	= this%chem%chem_ptr%species_number
		cell_size		= this%mesh%mesh_ptr%get_cell_edges_length()
		coordinate_system	= this%domain%get_coordinate_system_name()
		
		
		do plus = 1,2
			sign			= (-1)**plus
			bound_number	= bc%bc_markers(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))
			if( bound_number /= 0 ) then
				boundary_type_name = bc%boundary_types(bound_number)%get_type_name()
				select case(boundary_type_name)
					case('wall','symmetry_plane')
						if (( characteristic_speed(1) >= 0.0_dkind )	.and.&
							( characteristic_speed(2) < 0.0_dkind )		.and.&
							( characteristic_speed(3) >= 0.0_dkind )) then	
							!# ���������� ����� ����� �������, ������ �����. 
							if (sign == -1) then
								v_f_new%pr(dim)%cells(dim,i,j,k)	=	0.0_dkind 
								do dim1 = 1,dimensions
									if( dim1 /= dim) then							
										v_f_new%pr(dim1)%cells(dim,i,j,k)	=	v%pr(dim1)%cells(i,j,k)
									end if
								end do		
								p_f_new%cells(dim,i,j,k)			=	-q_corrected(1)	/ G_half
				!				p_f_new%cells(dim,i,j,k)			=	p%cells(i,j,k)  / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))
								rho_f_new%cells(dim,i,j,k)			=	rho%cells(i,j,k)  !/ mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) - 0.5_dkind*cell_size(1))
				!				rho_f_new%cells(dim,i,j,k)			=	rho_f_new%cells(dim,i+1,j,k)  / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) - cell_size(1)) * (mesh%mesh(1,i,j,k) - cell_size(1))
								
								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k)	= 	Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k) = max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind) / spec_summ
								end do
							end if
							!# ���������� ����� ����� �������, ������ ������. 
							if (sign == 1) then
								v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = 0.0_dkind
								do dim1 = 1, dimensions
									if (dim1 /= dim) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= v_inv_corrected(dim1,2)
									end if
								end do
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			= r_corrected(2)/G_half
								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			= (p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)
								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) 	= Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))  = max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind) / spec_summ
								end do								
							end if
						end if
						if (( characteristic_speed(1) >= 0.0_dkind )	.and.&
							( characteristic_speed(2) < 0.0_dkind )		.and.&
							( characteristic_speed(3) < 0.0_dkind )) then
							!# ���������� ����� ������ ������, ������ �����.
							if (sign == -1) then
								p_f_new%cells(dim,i,j,k)			=	-q_corrected(1)/ G_half
								rho_f_new%cells(dim,i,j,k)			=	(p_f_new%cells(dim,i,j,k)	-	v_inv_corrected(dim,1))	/ (v_s%cells(i,j,k)**2)
								v_f_new%pr(dim)%cells(dim,i,j,k)	=	0.0_dkind
								do dim1 = 1,dimensions
									if( dim1 /= dim) then
										v_f_new%pr(dim1)%cells(dim,i,j,k)	=	v_inv_corrected(dim1,1)
									end if
								end do
								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k)	= 	Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k) = max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind) / spec_summ
								end do
							end if
							!# ���������� ����� ������ ������, ������ ������. 
							if (sign == 1) then
								v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = 0.0_dkind
								do dim1 = 1, dimensions
									if (dim1 /= dim) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= v%pr(dim1)%cells(i,j,k)
									end if
								end do
								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			= rho%cells(i,j,k)
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			= r_corrected(2)/G_half
								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) 	= Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))  = max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind) / spec_summ
								end do	

							end if

						end if
									
					case ('outlet')
								
						! ******************* Acoustic outlet ***********************************						
						if (sign == 1) then						
							!# ����� ���������� ������ ��� ������ �������
							if (( characteristic_speed(1) >= 0.0_dkind )	.and.&
								( characteristic_speed(2) < 0.0_dkind )) then		!.and.&
								!( characteristic_speed(3) >= 0.0_dkind )) then		
							
								v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v%pr(dim)%cells(i,j,k)	!r_corrected(2) - p%cells(i,j,k)*G_half	

								!(g_inf * r_corrected(2) - G_half * g_inf * p_inf) / (G_half + g_inf) 
								!v%pr(dim)%cells(i,j,k)/v_s%cells(i,j,k) * ( 2.0_dkind * v_s%cells(i,j,k) - v_s_f(dim,i,j,k)) 
								!0.5_dkind * (r_corrected(2) + q_corrected(2)) !sqrt(sqrt(((p%cells(i,j,k)-p_inf)*(rho%cells(i,j,k)-rho_inf)/(rho%cells(i,j,k)*rho_inf))**2))
													
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	 p%cells(i,j,k) ! / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))   !(r_corrected(2) - v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))/G_half

								!(r_corrected(2) + g_inf * p_inf)/( G_half + g_inf )
								!(r_corrected(2) - v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))/G_half
													
								if ( characteristic_speed(3) >= 0.0_dkind ) then
									rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	rho%cells(i,j,k) ! / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)	!rho%cells(i,j,k)	!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)
								else
									rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	rho%cells(i,j,k) ! / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - (p_inf) + c_inf**2 * rho_inf) / (c_inf**2)			!rho%cells(i,j,k)	!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - p_inf + c_inf**2 * rho_inf) / (c_inf**2)
								end if

								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) 	= Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))  = max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind) / spec_summ
								end do	
										
								E_f_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	E_f%cells(i,j,k)

							end if
						end if
						if (sign == -1) then
							!# ����� ���������� ������ ��� ������ �������
							if (( characteristic_speed(1) >= 0.0_dkind )	.and.&
								( characteristic_speed(2) < 0.0_dkind )) then		!.and.&
								!( characteristic_speed(3) >= 0.0_dkind )) then		
							
								v_f_new%pr(dim)%cells(dim,i,j,k)	=	v%pr(dim)%cells(i,j,k)	!r_corrected(2) - p%cells(i,j,k)*G_half	

								!(g_inf * r_corrected(2) - G_half * g_inf * p_inf) / (G_half + g_inf) 
								!v%pr(dim)%cells(i,j,k)/v_s%cells(i,j,k) * ( 2.0_dkind * v_s%cells(i,j,k) - v_s_f(dim,i,j,k)) 
								!0.5_dkind * (r_corrected(2) + q_corrected(2)) !sqrt(sqrt(((p%cells(i,j,k)-p_inf)*(rho%cells(i,j,k)-rho_inf)/(rho%cells(i,j,k)*rho_inf))**2))
													
								p_f_new%cells(dim,i,j,k)			=	 p%cells(i,j,k) ! / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))   !(r_corrected(2) - v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))/G_half

								!(r_corrected(2) + g_inf * p_inf)/( G_half + g_inf )
								!(r_corrected(2) - v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)))/G_half
													
								if ( characteristic_speed(3) >= 0.0_dkind ) then
									rho_f_new%cells(dim,i,j,k)			=	rho%cells(i,j,k) ! / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)	!rho%cells(i,j,k)	!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)
								else
									rho_f_new%cells(dim,i,j,k)			=	rho%cells(i,j,k) ! / mesh%mesh(1,i,j,k) / mesh%mesh(1,i,j,k)  * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1)) * (mesh%mesh(1,i,j,k) + 0.5_dkind*cell_size(1))!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - (p_inf) + c_inf**2 * rho_inf) / (c_inf**2)			!rho%cells(i,j,k)	!(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - p_inf + c_inf**2 * rho_inf) / (c_inf**2)
								end if

								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k) 	= Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k)  = max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind) / spec_summ
								end do	
										
								E_f_f_new%cells(dim,i,j,k)			=	E_f%cells(i,j,k)

							end if						
						end if
												
						! ******************* Shock outlet ***********************************
							
						if (( characteristic_speed(1) >= 0.0_dkind ).and.&
							( characteristic_speed(2) >= 0.0_dkind ).and.&
							( characteristic_speed(3) >= 0.0_dkind )) then
											
							p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= 0.5_dkind * (r_corrected(2) - q_corrected(2)) / G_half
											
							rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = (p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)
											
							do dim1 = 1,dimensions
								if ( dim == dim1 ) then 
									v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	0.5_dkind * (r_corrected(2) + q_corrected(2))
								else
									v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_inv_corrected(dim1,2)
									if ( characteristic_speed(3) == 0 ) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = v_f(dim1,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
									end if
								end if
							end do
						end if

					case ('inlet')
							
						G_half_inf = 1.0_dkind / (rho%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))*v_s%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)))
						r_inf = v%pr(dim)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) + G_half_inf * p%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))	
						q_inf = v%pr(dim)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) - G_half_inf * p%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))	
						s_inf = p%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) - v_s%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))**2 * rho%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))
					
						! ******************* Acoustic inlet ***********************************					
						if (( characteristic_speed(1) >= 0.0_dkind )		.and.&
							( characteristic_speed(2) < 0.0_dkind ))then	!.and.&
					!		( characteristic_speed(3) >= 0.0_dkind )) then		
							if (sign == -1) then											!# ������� ����� (�����/������/�������), ����� �� ������� � ������� �����. 
								
								p_f_new%cells(dim,i,j,k)			=	(r_inf - q_corrected(1))/(G_half_inf + G_half)
								v_f_new%pr(dim)%cells(dim,i,j,k)	=	(G_half*r_inf + G_half_inf*q_corrected(1))/(G_half_inf + G_half)
								rho_f_new%cells(dim,i,j,k)			=	(p_f_new%cells(dim,i,j,k) - s_inf)/v_s%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))**2		
								
					!			print *, rho_f_new%cells(dim,i,j,k), rho%cells(i,j,k)

								do dim1 = 1, dimensions
									if (dim1 /= dim) then
										v_f_new%pr(dim1)%cells(dim,i,j,k)	= 0.0_dkind
									end if
								end do
								
								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k)	= 	Y%pr(spec)%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i,j,k) = max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind) / spec_summ
								end do
								
								E_f_f_new%cells(dim,i,j,k)			=	E_f%cells(i-I_m(dim,1),j-I_m(dim,2),k-I_m(dim,3))
								
							end if
							if (sign == 1) then
							
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	(r_corrected(2) - q_inf)/(G_half_inf + G_half)
								v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	(G_half_inf*r_corrected(2) + G_half*q_inf)/(G_half_inf + G_half)
								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2))/v_s%cells(i,j,k)**2								
							
								do dim1 = 1, dimensions
									if (dim1 /= dim) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= v_inv_corrected(dim1,2)
									end if
								end do

								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) 	= Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))  = max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind) / spec_summ
								end do								
							end if
						end if
						if (( characteristic_speed(1) >= 0.0_dkind )	.and.&
							( characteristic_speed(2) < 0.0_dkind )		.and.&
							( characteristic_speed(3) < 0.0_dkind )) then
						!	if (sign == -1) then
						!		p_f_new%cells(dim,i,j,k)			=	(r_inf - q_corrected(1))/(G_half_inf + G_half)
						!		v_f_new%pr(dim)%cells(dim,i,j,k)	=	(G_half*r_inf + G_half_inf*q_corrected(1))/(G_half_inf + G_half)
						!		rho_f_new%cells(dim,i,j,k)			=	(p_f_new%cells(dim,i,j,k) - v_inv_corrected(dim,1))/v_s%cells(i,j,k)**2								
      !
						!		do dim1 = 1, dimensions
						!			if (dim1 /= dim) then
						!				v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= v_inv_corrected(dim1,1)
						!			end if
						!		end do
						!		
						!		spec_summ = 0.0_dkind
						!		do spec = 1,species_number
						!			Y_f_new%pr(spec)%cells(dim,i,j,k)	= 	Y%pr(spec)%cells(i,j,k)  	
						!			spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind)
						!		end do
						!		do spec = 1,species_number
						!			Y_f_new%pr(spec)%cells(dim,i,j,k) = max(Y_f_new%pr(spec)%cells(dim,i,j,k), 0.0_dkind) / spec_summ
						!		end do
						!	end if
							if (sign == 1) then
								p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	(r_corrected(2) - q_inf)/(G_half_inf + G_half)
								v_f_new%pr(dim)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	(G_half_inf*r_corrected(2) + G_half*q_inf)/(G_half_inf + G_half)
								rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))			=	(p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - s_inf)/v_s%cells(i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))**2								
							
								do dim1 = 1, dimensions
									if (dim1 /= dim) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= 0.0_dkind
									end if
								end do

								spec_summ = 0.0_dkind
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) 	= Y%pr(spec)%cells(i,j,k)  	
									spec_summ = spec_summ + max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind)
								end do
								do spec = 1,species_number
									Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))  = max(Y_f_new%pr(spec)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)), 0.0_dkind) / spec_summ
								end do	

							end if

						end if					
																		
						! ******************* Shock inlet ***********************************
							
						if (( characteristic_speed(1) >= 0.0_dkind ).and.&
							( characteristic_speed(2) >= 0.0_dkind ).and.&
							( characteristic_speed(3) >= 0.0_dkind )) then
											
							p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	= 0.5_dkind * (r_corrected(2) - q_corrected(2)) / G_half
											
							rho_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = (p_f_new%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) - v_inv_corrected(dim,2)) / (v_s%cells(i,j,k)**2)
											
							do dim1 = 1,dimensions
								if ( dim == dim1 ) then 
									v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	0.5_dkind * (r_corrected(2) + q_corrected(2))
								else
									v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))	=	v_inv_corrected(dim1,2)
									if ( characteristic_speed(3) == 0 ) then
										v_f_new%pr(dim1)%cells(dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3)) = v_f(dim1,dim,i+I_m(dim,1),j+I_m(dim,2),k+I_m(dim,3))
									end if
								end if
							end do
						end if
	
				end select
			end if
		end do
		end associate

	end subroutine

	subroutine apply_boundary_conditions_main(this)

		class(cabaret_solver)		,intent(inout)		:: this

		integer					:: dimensions
		integer	,dimension(3,2)	:: cons_utter_loop, cons_inner_loop
		character(len=20)		:: boundary_type_name
		real(dkind)				:: farfield_density, farfield_pressure, wall_temperature

		integer	:: sign, bound_number
		integer :: i,j,k,plus,dim,dim1,dim2,specie_number

		dimensions			= this%domain%get_domain_dimensions()
		cons_utter_loop		= this%domain%get_local_utter_cells_bounds()	
		cons_inner_loop		= this%domain%get_local_inner_cells_bounds()	
		
		associate(  T				=> this%T%s_ptr					, &
					mol_mix_conc	=> this%mol_mix_conc%s_ptr		, &
					p				=> this%p%s_ptr					, &
					rho				=> this%rho%s_ptr				, &
					v				=> this%v%v_ptr					, &
					v_f_new			=> this%v_f_new%v_ptr			, &
					v_s				=> this%v_s%s_ptr				, &
					Y				=> this%Y%v_ptr					, &
					bc				=> this%boundary%bc_ptr			, &
					mesh			=> this%mesh%mesh_ptr)

		!$omp parallel default(none)  private(i,j,k,plus,dim,dim1,sign,bound_number,farfield_pressure,farfield_density,wall_temperature,boundary_type_name) , &
		!$omp& firstprivate(this)	,&
		!$omp& shared(bc,dimensions,p,rho,T,mol_mix_conc,v,v_s,Y,cons_utter_loop, cons_inner_loop)
		!$omp do collapse(3) schedule(static)

			do k = cons_inner_loop(3,1),cons_inner_loop(3,2)
			do j = cons_inner_loop(2,1),cons_inner_loop(2,2)
			do i = cons_inner_loop(1,1),cons_inner_loop(1,2)
				if(bc%bc_markers(i,j,k) == 0) then
					do dim = 1,dimensions
						do plus = 1,2
							sign			= (-1)**plus
							!if(((i+sign)*I_m(dim,1) + (j+sign)*I_m(dim,2) + (k+sign)*I_m(dim,3) <= cons_utter_loop(dim,2)).and. &
							!   ((i+sign)*I_m(dim,1) + (j+sign)*I_m(dim,2) + (k+sign)*I_m(dim,3) >= cons_utter_loop(dim,1))) then

								bound_number	= bc%bc_markers(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))
								if( bound_number /= 0 ) then

									boundary_type_name = bc%boundary_types(bound_number)%get_type_name()
									select case(boundary_type_name)
										case('wall')

											p%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))		= p%cells(i,j,k)
											rho%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))	= rho%cells(i,j,k)
											T%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))		= T%cells(i,j,k)
											mol_mix_conc%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))		= mol_mix_conc%cells(i,j,k)

											v_s%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))	= v_s%cells(i,j,k)
									
											do dim1 = 1, dimensions
												if(dim1 == dim) then
													v%pr(dim1)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) = - v%pr(dim1)%cells(i,j,k)
												else
													v%pr(dim1)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) = v%pr(dim1)%cells(i,j,k)
												end if
											end do

											do specie_number = 1, this%chem%chem_ptr%species_number
												Y%pr(specie_number)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3))	=	Y%pr(specie_number)%cells(i,j,k)
											end do
			
											if(bc%boundary_types(bound_number)%is_conductive()) then
												wall_temperature = bc%boundary_types(bound_number)%get_wall_temperature()
												T%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) = wall_temperature
											end if
											if(.not.bc%boundary_types(bound_number)%is_slip()) then
												do dim1 = 1, dimensions
													if(dim1 /= dim) then
														v%pr(dim1)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) = - v%pr(dim1)%cells(i,j,k) 
														! v%pr(dim1)%cells(i-sign*I_m(dim,1),j-sign*I_m(dim,2),k-sign*I_m(dim,3)) - 6.0_dkind * v%pr(dim1)%cells(i,j,k) 
														!- 10.0_dkind * v%pr(dim1)%cells(i,j,k)
													end if
												end do
											end if


										case ('outlet')
											farfield_pressure	= bc%boundary_types(bound_number)%get_farfield_pressure()
											farfield_density	= bc%boundary_types(bound_number)%get_farfield_density()
											v%pr(dim)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) =  sign*sqrt(abs((p%cells(i,j,k) - farfield_pressure)*(rho%cells(i,j,k) - farfield_density)/farfield_density/rho%cells(i,j,k)))
										case ('inlet')
										!	farfield_pressure	= bc%boundary_types(bound_number)%get_farfield_pressure()
										!	farfield_density	= bc%boundary_types(bound_number)%get_farfield_density()
										!	v%pr(dim)%cells(i+sign*I_m(dim,1),j+sign*I_m(dim,2),k+sign*I_m(dim,3)) = -sign*sqrt(abs((p%cells(i,j,k) - farfield_pressure)*(rho%cells(i,j,k) - farfield_density)/farfield_density/rho%cells(i,j,k)))
									end select

								end if
							!end if
						end do
					end do
				end if
			end do
			end do
			end do

		!$omp end do nowait
		!$omp end parallel

		end associate

	end subroutine
	
	subroutine calculate_time_step(this)

#ifdef mpi
	use MPI
#endif

		class(cabaret_solver)	,intent(inout)	:: this
		
		real(dkind)	:: delta_t_interm, time_step(1), velocity_value
		real(dkind)	,dimension(:)	,allocatable	,save	:: time_step_array

		integer						:: dimensions
		integer						:: processor_rank, processor_number, mpi_communicator

		integer		,dimension(3,2)	:: cons_inner_loop
		real(dkind)	,dimension(3)	:: cell_size
		integer	:: sign
		integer :: i,j,k,dim,error

		processor_rank		= this%domain%get_processor_rank()
		mpi_communicator	= this%domain%get_mpi_communicator()

		if (.not.allocated(time_step_array)) then
			processor_number = this%domain%get_mpi_communicator_size()
			allocate(time_step_array(processor_number))
		end if

		time_step(1)	= this%initial_time_step

		associate(  v				=> this%v%v_ptr		, &
					v_s				=> this%v_s%s_ptr		, &
					bc				=> this%boundary%bc_ptr	, &
					mesh			=> this%mesh%mesh_ptr)
		
		dimensions			= this%domain%get_domain_dimensions()
		cons_inner_loop		= this%domain%get_local_inner_cells_bounds()
		cell_size			= mesh%get_cell_edges_length()					
					
		!!$omp parallel default(shared)  private(i,j,k,dim,delta_t_interm,velocity_value) , &
		!!$omp& firstprivate(this)	,&
		!!$omp& shared(v,v_s,mesh,bc,time_step)
		!!$omp do collapse(3) schedule(static) reduction(min:time_step)
					
		do k = cons_inner_loop(3,1),cons_inner_loop(3,2)
		do j = cons_inner_loop(2,1),cons_inner_loop(2,2)
		do i = cons_inner_loop(1,1),cons_inner_loop(1,2)
			if(bc%bc_markers(i,j,k) == 0) then
				velocity_value		= 0.0_dkind
				do dim = 1,dimensions
					velocity_value = velocity_value + v%pr(dim)%cells(i,j,k)*v%pr(dim)%cells(i,j,k)
				end do
				delta_t_interm = minval(cell_size,cell_size > 0.0_dkind) / (sqrt(velocity_value) + v_s%cells(i,j,k))
				if (delta_t_interm < time_step(1)) then
					time_step(1) = delta_t_interm
				end if
			end if
		end do
		end do
		end do
	
		!!$omp end do nowait
		!!$omp end parallel

		time_step_array(processor_rank+1) = time_step(1) 
		
#ifdef mpi					
		call mpi_gather(time_step,1,MPI_DOUBLE_PRECISION,time_step_array,1,MPI_DOUBLE_PRECISION,0,mpi_communicator,error)
#endif
		
		if (processor_rank == 0) then
			do i = 0,size(time_step_array) - 1 
				if (time_step_array(i+1) < time_step(1)) time_step(1) = time_step_array(i+1)
			end do
		end if

#ifdef mpi	
		call mpi_bcast(time_step,1,MPI_DOUBLE_PRECISION,0,mpi_communicator,error)
#endif

		this%time_step = this%courant_fraction * time_step(1)

!		if(time_step(1) < 1.6e-08_dkind) then
!			this%time_step = 0.0025 * time_step(1)
!			print *, 'Time step was reduced. Co = 1: ',time_step(1), '. Reduced: ', this%time_step
!		end if

		end associate
			
	end subroutine
	
	subroutine set_CFL_coefficient(this,coefficient)
		class(cabaret_solver)	,intent(inout)	:: this
		real(dkind)				,intent(in)		:: coefficient
	
		this%courant_fraction = coefficient
		
	end subroutine
	
	pure function get_time_step(this)
		real(dkind)						:: get_time_step
		class(cabaret_solver)	,intent(in)		:: this

		get_time_step = this%time_step
	end function

	pure function get_time(this)
		real(dkind)						:: get_time
		class(cabaret_solver)	,intent(in)		:: this

		get_time = this%time
	end function

end module
