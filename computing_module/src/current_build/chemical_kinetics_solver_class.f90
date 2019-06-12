module chemical_kinetics_solver_class

	use kind_parameters
	use global_data
	use field_pointers
	use boundary_conditions_class
	use data_manager_class
	use computational_domain_class
	use thermophysical_properties_class
	use chemical_properties_class
	
	implicit none

#ifdef OMP
	include "omp_lib.h"
#endif

	private
	public  :: chemical_kinetics_solver, chemical_kinetics_solver_c

	real(dkind) ,dimension(:)       ,allocatable    :: mixture_concentration
	real(dkind) ,dimension(:,:)     ,allocatable    :: rate_constants
	integer     ,dimension(:,:,:)   ,allocatable    :: chemical_coeffs
	real(dkind) ,dimension(:)		,allocatable    :: conc_in, conc_out
	integer     ,dimension(:)		,allocatable    :: IWORK
	real(dkind) ,dimension(:)		,allocatable    :: WORK
	real(dkind)										:: temperature, pressure 
	
	!$OMP THREADPRIVATE(mixture_concentration,rate_constants,chemical_coeffs,conc_in, conc_out,IWORK,WORK, temperature, pressure)

	integer			:: reactions_number
	integer			:: species_number

	integer			:: counter = 0

	
	type(field_scalar_cons)	,target	:: E_f_prod_chem
	type(field_vector_cons)	,target	:: Y_prod_chem

	interface
		function d1mach(I)
			real(kind=8)				:: d1mach
			integer		, intent(in)	:: i
		end function d1mach
		subroutine ddriv3(N, T, Y, F, NSTATE, TOUT, NTASK, NROOT, EPS,	&
        EWT, IERROR, MINT, MITER, IMPL, ML, MU, MXORD, HMAX, WORK,		&
        LENW, IWORK, LENIW, JACOBN, FA, NDE, MXSTEP, G, USERS, IERFLG)
			EXTERNAL F, JACOBN, FA, G, USERS
			DOUBLE PRECISION AE, BIG, EPS, EWT(*), G, GLAST, GNOW, H, HMAX,		&
				HSIGN, HUSED, NROUND, RE, D1MACH, SIZE, DNRM2, SUM, T, TLAST,	&
				TOUT, TROOT, UROUND, WORK(*), Y(*)
			INTEGER I, IA, IAVGH, IAVGRD, ICNVRG, IDFDY, IEL, IERFLG, IERROR,		&
					IFAC, IFLAG, IGNOW, IH, IHMAX, IHOLD, IHSIGN, IHUSED,			&
					IJROOT, IJSTPL, IJTASK, IMNT, IMNTLD, IMPL, IMTR, IMTRLD,		&
					IMTRSV, IMXERR, IMXORD, IMXRDS, INDMXR, INDPRT, INDPVT,		&
					INDTRT, INFE, INFO, INJE, INQ, INQUSE, INROOT, INRTLD,		&
					INSTEP, INWAIT, IRC, IRMAX, IROOT, IMACH1, IMACH4, ISAVE1,	&
					ISAVE2, IT, ITOUT, ITQ, ITREND, ITROOT, IWORK(*), IYH,		&
					IYWT, J, JSTATE, JTROOT, LENCHK, LENIW, LENW, LIWCHK,			&
					MATDIM, MAXORD, MINT, MITER, ML, MU, MXORD, MXSTEP, N,		&
					NDE, NDECOM, NPAR, NROOT, NSTATE, NSTEPL, NTASK
			LOGICAL CONVRG
			CHARACTER INTGR1*8, INTGR2*8, RL1*16, RL2*16
			PARAMETER(NROUND = 20.D0)
			PARAMETER(IAVGH = 1, IHUSED = 2, IAVGRD = 3,							&
					IEL = 4, IH = 160, IHMAX = 161, IHOLD = 162,				&
					IHSIGN = 163, IRC = 164, IRMAX = 165, IT = 166,				&
					ITOUT = 167, ITQ = 168, ITREND = 204, IMACH1 = 205,			&
					IMACH4 = 206, IYH = 251,									&
					INDMXR = 1, INQUSE = 2, INSTEP = 3, INFE = 4, INJE = 5,		&
					INROOT = 6, ICNVRG = 7, IJROOT = 8, IJTASK = 9,				&
					IMNTLD = 10, IMTRLD = 11, INQ = 12, INRTLD = 13,			&
					INDTRT = 14, INWAIT = 15, IMNT = 16, IMTRSV = 17,			&
					IMTR = 18, IMXRDS = 19, IMXORD = 20, INDPRT = 21,			&
					IJSTPL = 22, INDPVT = 51)
		end subroutine ddriv3
	end interface

	type 	:: chemical_kinetics_solver
		type(field_scalar_cons_pointer)	:: T, p, rho, E_f_prod
		type(field_vector_cons_pointer)	:: Y, Y_prod

		type(computational_domain)					:: domain

		type(thermophysical_properties_pointer)		:: thermo
		type(chemical_properties_pointer)			:: chem
		type(boundary_conditions_pointer)			:: boundary
		character(len=20)							:: ODE_solver = 'slatec'
	contains
		procedure				:: solve_chemical_kinetics
		procedure	,private	:: calculate_rate_constants
	end type

	interface   chemical_kinetics_solver_c
		module procedure	constructor
	end interface

contains

	type(chemical_kinetics_solver)	function constructor(manager)
		type(data_manager)				,intent(inout)	:: manager

		type(field_scalar_cons_pointer)	:: scal_ptr
		type(field_vector_cons_pointer)	:: vect_ptr
		type(field_tensor_cons_pointer)	:: tens_ptr
		
		real(dkind) ::  TIN
		
		
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'temperature')
		constructor%T%s_ptr						=> scal_ptr%s_ptr
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'pressure')
		constructor%p%s_ptr						=> scal_ptr%s_ptr		
		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'density')
		constructor%rho%s_ptr					=> scal_ptr%s_ptr

		call manager%get_cons_field_pointer_by_name(scal_ptr,vect_ptr,tens_ptr,'specie_molar_concentration')
		constructor%Y%v_ptr						=> vect_ptr%v_ptr

		call manager%create_scalar_field(E_f_prod_chem	,'energy_production_chemistry'	,'E_f_prod_chem')
		constructor%E_f_prod%s_ptr				=> E_f_prod_chem

		call manager%create_vector_field(Y_prod_chem	,'specie_production_chemistry'	,'Y_prod_chem', 'chemical')
		constructor%Y_prod%v_ptr				=> Y_prod_chem

		constructor%boundary%bc_ptr 			=> manager%boundary_conditions_pointer%bc_ptr

		constructor%domain				= manager%domain
		constructor%thermo%thermo_ptr	=> manager%thermophysics%thermo_ptr
		constructor%chem%chem_ptr		=> manager%chemistry%chem_ptr

		reactions_number    = manager%chemistry%chem_ptr%reactions_number
		species_number      = manager%chemistry%chem_ptr%species_number

		!$omp parallel
		allocate(rate_constants(reactions_number,2))
		allocate(conc_in(species_number))
		allocate(conc_out(species_number))
		allocate(mixture_concentration(reactions_number))
		allocate(chemical_coeffs(4,reactions_number,2))
		allocate(WORK(species_number**2 + 10*species_number+250))
		allocate(IWORK(50+species_number))

		rate_constants	= 0.0_dkind
		conc_in			= 0.0_dkind
		conc_out		= 0.0_dkind
		mixture_concentration	= 0.0_dkind
		chemical_coeffs	= manager%chemistry%chem_ptr%chemical_coeffs
		WORK			= 0.0_dkind
		IWORK			= 0
		!$omp end parallel

	end function

	subroutine solve_chemical_kinetics(this,time_step)

		class(chemical_kinetics_solver)  ,intent(inout) :: this
		real(dkind)                                     :: time_step

		integer     ::  N,NSTATE,NTASK,NROOT,IERROR,MINT,MITER,IMPL,MU,ML,MXORD,MXSTEP,LENW,LENIW,NDE,MATDIM,IERFLG
		real(dkind) ::  EPS,HMAX,TIN,TOUT,TOUT2
		real(dkind) ,dimension(1)   ::  EWT

		integer						::  IER, ITOL, ITASK
		real(dkind)	,dimension(3)	::	ATOL(3) 
		real(dkind)					::	RTOL	
		
		real(dkind) :: specie_enthalpy

		logical	:: acetylene_flag
		integer	,dimension(3,2)	:: cons_inner_loop
		integer :: i,j,k,dim1,dim2, i_specie, i_react

		cons_inner_loop	= this%domain%get_local_inner_cells_bounds()

		if (this%chem%chem_ptr%get_chemical_specie_index('C2H2') /= 0) acetylene_flag	= .true.
		
		associate (	T				=> this%T%s_ptr								, &
					p				=> this%p%s_ptr								, &
					rho				=> this%rho%s_ptr							, &
					E_f_prod 		=> this%E_f_prod%s_ptr						, &
					Y				=> this%Y%v_ptr								, &
					Y_prod 			=> this%Y_prod%v_ptr						, &
					molar_masses    => this%thermo%thermo_ptr%molar_masses		, &
					enhanced_efficiencies    => this%chem%chem_ptr%enhanced_efficiencies	, &
					chem			=> this%chem%chem_ptr)
					

	!$omp parallel default(none) private(i,j,k,i_react,i_specie,specie_enthalpy,N,NSTATE,NTASK,NROOT,IERROR,MINT,MITER,IMPL,MU,ML,MXORD,MXSTEP,LENW,LENIW,NDE,MATDIM,IERFLG,EPS,HMAX,TIN,TOUT,EWT) , &
	!$omp& private(ITOL, RTOL, ATOL, ITASK, TOUT2, IER)	, &			
	!$omp& firstprivate(this)	, &
	!$omp& shared(T,p,rho,Y,E_f_prod,Y_prod,molar_masses,enhanced_efficiencies,time_step,species_number,reactions_number,cons_inner_loop,acetylene_flag)
	!$omp do collapse(3) schedule(static)

		do k = cons_inner_loop(3,1),cons_inner_loop(3,2)
		do j = cons_inner_loop(2,1),cons_inner_loop(2,2)
		do i = cons_inner_loop(1,1),cons_inner_loop(1,2)
			continue
			if (		(T%cells(i,j,k) >= 300.5_dkind) 	&
				!.and.	(T%cells(i,j,k) <= 5000.0_dkind)	&
				.and.	(this%boundary%bc_ptr%bc_markers(i,j,k) == 0)) then

				E_f_prod%cells(i,j,k)	= 0.0_dkind
				mixture_concentration	= 0.0_dkind

				do i_react	= 1,reactions_number
					do i_specie	= 1,species_number
						if (molar_masses(i_specie) /= 0.0_dkind) then
						mixture_concentration(i_react)	= mixture_concentration(i_react)           &
														+ Y%pr(i_specie)%cells(i,j,k)*rho%cells(i,j,k)/molar_masses(i_specie)*enhanced_efficiencies(i_react,i_specie)

						end if
					
					end do
					continue
				end do

				call this%calculate_rate_constants(T%cells(i,j,k))

				conc_in = 0.0_dkind
				do i_specie	= 1,species_number
					if (molar_masses(i_specie) /= 0.0_dkind) then
						conc_in(i_specie)	= Y%pr(i_specie)%cells(i,j,k)*rho%cells(i,j,k)/molar_masses(i_specie)
					else
						conc_in(i_specie)	= Y%pr(i_specie)%cells(i,j,k)
					end if
				end do
				conc_out	= conc_in

				! *******************************************************************
				!  *Solution of differential equations system for chemical kinetics*
				!  * SLATEC parameters *
				N       =   species_number
				NSTATE  =   1
				NTASK   =   1
				NROOT   =   0
				EPS     =   1.0e-8_dkind !D1MACH(4)**(1.0_dkind/3.0_dkind)
				EWT(1)  =   1.0e-4_dkind
				IERROR  =   3
				MINT    =   2
				MITER   =   2
				IMPL    =   0
				ML      =   0
				MU      =   0
				MXORD   =   5
				TIN     =   0.0_dkind
				TOUT    =   time_step
				TOUT2   =   0.0_dkind
				!=====================================
				HMAX    =   1.0E-7
				MXSTEP  =   5000
				LENW    =   N*N+(MXORD+5)*N+2*NROOT+250
				LENIW   =   N+50

				!=====================================
				NDE     =   N
				MATDIM  =   N
				IERFLG  =   0

				!=====================================
				!  * CVODE parameters *				
				ITOL	= 1
				RTOL	= 1.0E-4_dkind
				ATOL(1) = 1.0E-8_dkind
				ATOL(2) = 1.0E-8_dkind
				ATOL(3) = 1.0E-8_dkind
				ITASK	= 1

				temperature	= T%cells(i,j,k)
				pressure	= p%cells(i,j,k)

				if (this%ODE_solver == 'slatec') then
					call ddriv3(N,TIN,conc_out,fun,NSTATE,TOUT,NTASK,NROOT,EPS,EWT,IERROR,MINT	,&
								MITER,IMPL,ML,MU,MXORD,HMAX,WORK,LENW,IWORK,LENIW				,&
								fun,fun,NDE,MXSTEP,DUMMY,fun,IERFLG)		
				end if

								
				do i_specie	= 1,species_number
					if (molar_masses(i_specie) /= 0.0_dkind) then
			!		Y_prod%pr(i_specie)%cells(i,j,k) = (conc_out(i_specie) - conc_in(i_specie))/rho%cells(i,j,k)*molar_masses(i_specie)
						Y_prod%pr(i_specie)%cells(i,j,k) = (conc_out(i_specie) - conc_in(i_specie))*molar_masses(i_specie) / time_step
					else
						Y_prod%pr(i_specie)%cells(i,j,k) = (conc_out(i_specie) - conc_in(i_specie))
					end if
				end do

				do i_specie = 1,species_number
					specie_enthalpy = this%thermo%thermo_ptr%calculate_specie_enthalpy(T%cells(i,j,k),i_specie)
			!		E_f_prod%cells(i,j,k) = E_f_prod%cells(i,j,k) - specie_enthalpy*(conc_out(i_specie) - conc_in(i_specie))/rho%cells(i,j,k)
					E_f_prod%cells(i,j,k) = E_f_prod%cells(i,j,k) - specie_enthalpy*(conc_out(i_specie) - conc_in(i_specie)) / time_step
					continue
				end do
			else
				do i_specie	= 1,species_number
					Y_prod%pr(i_specie)%cells(i,j,k)	= 0.0_dkind
				end do
				E_f_prod%cells(i,j,k)				= 0.0_dkind
			end if

			continue
		end do
		end do
		end do

	!$omp end do nowait
	!$omp end parallel

		end associate

	end subroutine

	recursive subroutine calculate_rate_constants(this,Tin)

		class(chemical_kinetics_solver) ,intent(inout)  :: this
		real(dkind)                     ,intent(in)     :: Tin

		real(dkind)	,dimension(species_number)			:: s, h
		real(dkind)										:: d_s, d_h, d_nu
		real(dkind)										:: Kp, Kc, k_0, k_inf, reduced_pressure, mix_conc
		real(dkind)										:: c, n, d, F_cent, blending_function
		real(dkind)										:: T, dfd

		integer     :: i_react, i_component

		associate ( A				=> this%chem%chem_ptr%A						,&
					A_low			=> this%chem%chem_ptr%A_low					,&
					beta			=> this%chem%chem_ptr%beta					,&
					beta_low		=> this%chem%chem_ptr%beta_low				,&
					E_act			=> this%chem%chem_ptr%E_act					,&
					E_act_low	=> this%chem%chem_ptr%E_act_low			,&
					chem_coeffs	=> this%chem%chem_ptr%chemical_coeffs	,&
					Troe_coeffs	=> this%chem%chem_ptr%Troe_coeffs)
		
		T = min(Tin,10000.0_dkind)
						
		s = 0.0_dkind
		h = 0.0_dkind

		do 	i_component= 1,	species_number
			s(i_component) = this%thermo%thermo_ptr%calculate_specie_entropy(T,i_component)
			h(i_component) = this%thermo%thermo_ptr%calculate_specie_enthalpy(T,i_component)
		end do

		do i_react = 1, reactions_number

		d_s		= 0.0_dkind
		d_h		= 0.0_dkind
		d_nu	= 0.0_dkind

		do i_component = 2, chem_coeffs(1,i_react,2)+1
			if(chem_coeffs(i_component,i_react,2) == species_number + 1) cycle
			d_s = d_s + s(chem_coeffs(i_component,i_react,2))
			d_h = d_h + h(chem_coeffs(i_component,i_react,2))
		end do

		do i_component = 2, chem_coeffs(1,i_react,1)+1
			if(chem_coeffs(i_component,i_react,1) == species_number + 1) cycle
			d_s = d_s - s(chem_coeffs(i_component,i_react,1))
			d_h = d_h - h(chem_coeffs(i_component,i_react,1))
		end do

		d_nu =  chem_coeffs(1,i_react,2) - chem_coeffs(1,i_react,1)

		select case (this%chem%chem_ptr%reactions_type(i_react))
			case(0)         ! without M or (M), nonduplicate, reversible
				rate_constants(i_react,1) = A(i_react)*(T**beta(i_react))*exp(-E_act(i_react)/r_gase_J/T)

				Kp = exp(d_s/r_gase_j - d_h/r_gase_j/T)
				Kc = Kp * (100000.0_dkind/r_gase_j/T) ** d_nu

				rate_constants(i_react,2) = rate_constants(i_react,1) / Kc
			case(1)         ! reversible +M
				rate_constants(i_react,1) = A(i_react)*(T**beta(i_react))*exp(-E_act(i_react)/r_gase_J/T)

				Kp = exp(d_s/r_gase_j - d_h/r_gase_j/T)
				Kc = Kp * (100000.0_dkind/r_gase_j/T) ** d_nu

				rate_constants(i_react,2) = rate_constants(i_react,1) / Kc
			case(2)         ! Lindemann form
				k_0     = A_low (i_react)*(T**beta_low  (i_react))*exp(-E_act_low   (i_react)/r_gase_J/T)
				k_inf   = A     (i_react)*(T**beta      (i_react))*exp(-E_act       (i_react)/r_gase_J/T)

				reduced_pressure = k_0 * mixture_concentration(i_react) / k_inf

				rate_constants(i_react,1) = k_inf * (reduced_pressure / (1.0_dkind + reduced_pressure))

				Kp = exp(d_s/r_gase_j - d_h/r_gase_j/T)
				Kc = Kp * (100000.0_dkind/r_gase_j/T) ** d_nu

				rate_constants(i_react,2) = rate_constants(i_react,1) / Kc
			case(3)         ! Troe form
			
				k_0     = exp(-E_act_low   (i_react)/r_gase_J/T)
				k_inf   = exp(-E_act       (i_react)/r_gase_J/T)
			
				k_0     = A_low (i_react)*(T**beta_low  (i_react))*k_0
				k_inf   = A     (i_react)*(T**beta      (i_react))*k_inf

				reduced_pressure = k_0 * mixture_concentration(i_react) / k_inf

				F_cent = (1.0_dkind - Troe_coeffs(i_react,1))*exp(-T/Troe_coeffs(i_react,2)) + Troe_coeffs(i_react,1)*exp(-T/Troe_coeffs(i_react,3)) + exp(-Troe_coeffs(i_react,4)/T)

				c = -0.4_dkind - 0.67_dkind * log(F_cent)
				n = 0.75_dkind - 1.27_dkind * log(F_cent)
				d = 0.14_dkind

				if (reduced_pressure /= 0.0_dkind) then
					blending_function = F_cent ** (1.0_dkind/ (1.0_dkind + ((log(reduced_pressure) + c)/(n - d*(log(reduced_pressure)+c)))**2))
				else
					blending_function = F_cent ** (-1.0_dkind / d)
				end if
					
				dfd = log(blending_function)
				
				rate_constants(i_react,1) = k_inf * (reduced_pressure / (1.0_dkind + reduced_pressure)) * blending_function

				Kp = exp(d_s/r_gase_j - d_h/r_gase_j/T)
				Kc = Kp * (100000.0_dkind/r_gase_j/T) ** d_nu

				rate_constants(i_react,2) = rate_constants(i_react,1) / Kc
			case(4)         ! duplicate
			case(5)         ! one-directed
				rate_constants(i_react,1) = A(i_react)*(T**beta(i_react))*exp(-E_act(i_react)/r_gase_J/T)
				rate_constants(i_react,2) = 0.0_dkind
			case(6)         ! one-directed +M
				rate_constants(i_react,1) = A(i_react)*(T**beta(i_react))*exp(-E_act(i_react)/r_gase_J/T)
				rate_constants(i_react,2) = 0.0_dkind
			case(7)         !one-directed (+M) Lindemann or Troe
				k_0     = A_low (i_react)*(T**beta_low  (i_react))*exp(-E_act_low   (i_react)/r_gase_J/T)
				k_inf   = A     (i_react)*(T**beta      (i_react))*exp(-E_act       (i_react)/r_gase_J/T)

				reduced_pressure = k_0 * mixture_concentration(i_react) / k_inf

				rate_constants(i_react,1) = k_inf * (reduced_pressure / (1.0_dkind + reduced_pressure))
				rate_constants(i_react,2) = 0.0_dkind
		end select

		end do

		continue

		end associate

	end subroutine

	recursive subroutine fun(N,T,Z,ZDOT)

		real(dkind)                             ,intent(in)     :: T
		integer                                 ,intent(in)     :: N

		real(dkind) ,dimension(species_number)  ,intent(in)     :: Z
		real(dkind) ,dimension(species_number)  ,intent(out)    :: ZDOT

		real(dkind) :: forward_rate, reverse_rate
!		integer     ,save   :: counter = 0
		integer     :: i_react, i_specie, i_coeff

		ZDOT = 0.0_dkind

		do i_react  = 1,reactions_number
			forward_rate = rate_constants(i_react,1)
			do i_coeff = 2,chemical_coeffs(1,i_react,1)+1
				if (chemical_coeffs(i_coeff,i_react,1) == species_number + 1) then
					forward_rate = forward_rate * mixture_concentration(i_react)
					continue
				else
					forward_rate = forward_rate * Z(chemical_coeffs(i_coeff,i_react,1))
					continue
				end if
			end do
			reverse_rate = rate_constants(i_react,2)
			do i_coeff = 2,chemical_coeffs(1,i_react,2)+1
				if (chemical_coeffs(i_coeff,i_react,2) == species_number + 1) then
					reverse_rate = reverse_rate * mixture_concentration(i_react)
				else
					reverse_rate = reverse_rate * Z(chemical_coeffs(i_coeff,i_react,2))
				end if
			end do
			do i_specie   = 1,species_number
				do i_coeff = 2,chemical_coeffs(1,i_react,1)+1
					if (chemical_coeffs(i_coeff,i_react,1) == i_specie) ZDOT(i_specie) = ZDOT(i_specie) - forward_rate + reverse_rate
				end do
				do i_coeff = 2,chemical_coeffs(1,i_react,2)+1
					if (chemical_coeffs(i_coeff,i_react,2) == i_specie) ZDOT(i_specie) = ZDOT(i_specie) - reverse_rate + forward_rate
				end do
			end do
		end do

		counter = counter + 1
		
	!	print *, counter
		
		continue
	end subroutine	
	
	DOUBLE PRECISION FUNCTION DUMMY(N, T, Y, IROOT)

		INTEGER :: N
		DOUBLE PRECISION :: T
		INTEGER :: IROOT
		DOUBLE PRECISION :: Y(:)
		DUMMY = T
	END FUNCTION

end module
