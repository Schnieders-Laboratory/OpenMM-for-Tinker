! -----------------------------------------------------------------------------
!     OpenMM(tm) HelloSodiumChloride example in Fortran 95 (June 2009)
! ------------------------------------------------------------------------------
! This is a complete, self-contained "hello world" example demonstrating 
! GPU-accelerated constant temperature simulation of a very simple system with
! just nonbonded forces, consisting of several sodium (Na+) and chloride (Cl-) 
! ions in implicit solvent. A multi-frame PDB file is written to stdout which 
! can be read by VMD or other visualization tool to produce an animation of the 
! resulting trajectory.
!
! Pay particular attention to the handling of units in this example. Incorrect
! handling of units is a very common error; this example shows how you can
! continue to work with Amber-style units like Angstroms, kCals, and van der
! Waals radii while correctly communicating with OpenMM in nm, kJ, and sigma.
!
! This example is written entirely in Fortran 95, using a Fortran interface 
! module which is NOT official parts of the OpenMM distribution.
! ------------------------------------------------------------------------------

!-------------------------------------------------------------------------------
!                ATOM, FORCE FIELD, AND SIMULATION PARAMETERS
!-------------------------------------------------------------------------------
! We'll define this module as a simplified example of the kinds of data
! structures that may already be in an MD program that is to be converted
! to use OpenMM. Note that we're using data in Angstrom and kcal units; we'll
! show how to safely convert to and from OpenMM's internal units as we go.
MODULE MyAtomInfo
    ! Simulation parameters
    ! ---------------------
    real*8 Temperature, FrictionInPerPs, SolventDielectric, SoluteDielectric
    parameter(Temperature        = 300) !Kelvins
    parameter(FrictionInPerPs    = 91)  !collisions per picosecond
    parameter(SolventDielectric  = 80)  !typical for water
    parameter(SoluteDielectric   = 2)   !typical for protein
    
    real*8 StepSizeInFs, ReportIntervalInFs, SimulationTimeInPs
    parameter(StepSizeInFs       = 2)   !integration step size (fs)
    parameter(ReportIntervalInFs = 50)  !how often for PDB frame (fs)
    parameter(SimulationTimeInPs = 100) !total simulation time (ps)
    
    ! Currently energy calculation is not available in the GPU kernels so
    ! asking for it requires slow Reference Platform computation at 
    ! reporting intervals. If you have a big system you'll want this off.
    logical, parameter :: WantEnergy = .true.

    ! Atom and force field information
    ! --------------------------------
    type Atom
        character*4       pdb
        real*8            mass, charge, vdwRadiusInAng, vdwEnergyInKcal
        real*8            gbsaRadiusInAng, gbsaScaleFactor
        real*8            initPosInAng(3)
        real*8            posInAng(3) ! leave room for runtime state info
    end type
    integer, parameter :: NumAtoms = 6
    type (Atom) :: atoms(NumAtoms) = (/ &
    ! pdb   mass charge vdwRad vdwEnergy  gbRad gbScale   initPos      runtime
Atom(' NA ',22.99,  1,  1.8680, 0.00277,  1.992,  0.8, (/ 8, 0,  0/), (/0,0,0/)),&
Atom(' CL ',35.45, -1,  2.4700, 0.1000,   1.735,  0.8, (/-8, 0,  0/), (/0,0,0/)),&
Atom(' NA ',22.99,  1,  1.8680, 0.00277,  1.992,  0.8, (/ 0, 9,  0/), (/0,0,0/)),&
Atom(' CL ',35.45, -1,  2.4700, 0.1000,   1.735,  0.8, (/ 0,-9,  0/), (/0,0,0/)),&
Atom(' NA ',22.99,  1,  1.8680, 0.00277,  1.992,  0.8, (/ 0, 0,-10/), (/0,0,0/)),&
Atom(' CL ',35.45, -1,  2.4700, 0.1000,   1.735,  0.8, (/ 0, 0, 10/), (/0,0,0/)) &
    /)
END MODULE

!-------------------------------------------------------------------------------
!                                MAIN PROGRAM
!-------------------------------------------------------------------------------
! This makes use of four subroutines that encapsulate all the OpenMM calls:
!     myInitializeOpenMM
!     myStepWithOpenMM
!     myGetOpenMMState
!     myTerminateOpenMM
! and one minimalist PDB file writer that has nothing to do with OpenMM:
!     myWritePDBFrame
! All of these subroutines can be found later in this file. For use in a real
! MD code you would need to write your own interface routines along these lines.
! Note that the main program does NOT include the OpenMM module.
PROGRAM HelloSodiumChloride
    use MyAtomInfo

    ! Calculate the number of PDB frames we want to write out and how
    ! many steps to take on the GPU in between.
    integer NumReports, NumSilentSteps
    parameter(NumReports = (SimulationTimeInPs*1000 / ReportIntervalInFs + 0.5))
    parameter(NumSilentSteps = (ReportIntervalInFs / StepSizeInFs + 0.5))
    
    character*10 platformName; real*8 timeInPs, energyInKcal; integer frame

    ! This is an opaque handle to a container that holds the OpenMM runtime
    ! objects. You can use any type for this purpose as long as it is 
    ! big enough to hold a pointer. (If you use a pointer type you'll have
    ! to declare the subroutine interfaces before calling them.)
    integer*8 ommHandle

    ! Set up OpenMM data structures; returns platform name and handle.
    call myInitializeOpenMM(ommHandle, platformName)
 
    ! Run the simulation:
    !  (1) Write the first line of the PDB file and the initial configuration.
    !  (2) Run silently entirely within OpenMM between reporting intervals.
    !  (3) Write a PDB frame when the time comes.
    print "('REMARK  Using OpenMM platform ', A)", platformName
    call myGetOpenMMState(ommHandle, timeInPs, energyInKcal)
    call myWritePDBFrame(0, timeInPs, energyInKcal)
    
    do frame = 1, NumReports
        call myStepWithOpenMM(ommHandle, NumSilentSteps)
        call myGetOpenMMState(ommHandle, timeInPs, energyInKcal)
        call myWritePDBFrame(frame, timeInPs, energyInKcal)
    end do
    
    ! Clean up OpenMM data structures.
    call myTerminateOpenMM(ommHandle)
END PROGRAM

!-------------------------------------------------------------------------------
!                                PDB FILE WRITER
!-------------------------------------------------------------------------------
! Given state data, output a single frame (pdb "model") of the trajectory
SUBROUTINE myWritePDBFrame(frameNum, timeInPs, energyInKcal)
    use MyAtomInfo; implicit none
    integer frameNum; real*8 timeInPs, energyInKcal

    integer n
    print "('MODEL',5X,I0)", frameNum
    print "('REMARK 250 time=', F0.3, ' picoseconds; Energy=', F0.3, ' kcal/mole')", &
        timeInPs, energyInKcal
    do n = 1,NumAtoms
        print "('ATOM  ', I5, ' ', A4, ' SLT     1    ', 3F8.3, '  1.00  0.00')",    &
            n, atoms(n)%pdb, atoms(n)%posInAng
    end do
    print "('ENDMDL')"
END SUBROUTINE 

!-------------------------------------------------------------------------------
!                            OpenMM-USING CODE
!-------------------------------------------------------------------------------
! The OpenMM Fortran interface module is included only at this point and below. 
! Normally these subroutines would be in a separate compilation module; we're 
! including them here for simplicity. We suggest that you write them in C++ 
! if possible, using extern "C" functions to make then callable from your
! Fortran main program. (See the C++ version of this example program for 
! an implementation of very similar routines.) However, these routines are 
! reimplemented entirely in Fortran 95 below in case you prefer.
!-------------------------------------------------------------------------------

! ------------------------------------------------------------------------------
!                      INITIALIZE OpenMM DATA STRUCTURES
! ------------------------------------------------------------------------------
! We take these actions here:
! (1) Load any available OpenMM plugins, e.g. Cuda and Brook.
! (2) Fill the OpenMM::System with the force field parameters we want to
!     use and the particular set of atoms to be simulated.
! (3) Create an Integrator and a Context associating the Integrator with
!     the System.
! (4) Select the OpenMM platform to be used.
! (5) Allocate a RuntimeObjects container to hang on to the System, 
!     Integrator, and Context.
! (6) Return an opaque handle to the RuntimeObjects and the name of the 
!     Platform in use.
!
! Note that this routine must understand the calling MD code's molecule and
! force field data structures so will need to be customized for each MD code.

SUBROUTINE myInitializeOpenMM(ommHandle, platformName)
    use OpenMM; use MyAtomInfo; implicit none
    integer*8,    intent(out) :: ommHandle
    character*10, intent(out) :: platformName

    ! This is the actual type of the opaque handle.
    type (OpenMM_RuntimeObjects) omm
    ! These are the objects we'll create here and store in the RuntimeObjects
    ! container for later access.
    type (OpenMM_System)     system
    type (OpenMM_Integrator) integrator
    type (OpenMM_Context)    context

    ! These are temporary OpenMM objects used and discarded here.
    type(OpenMM_Vec3Array)          initialPosInNm
    type(OpenMM_NonbondedForce)     nonbond
    type(OpenMM_GBSAOBCForce)       gbsa
    type(OpenMM_Force)              force ! generic Force
    type(OpenMM_LangevinIntegrator) langevin
    integer n

    type(OpenMM_String) dir

    ! Create a string, get the name of the default plugins directory, 
    ! and then load all the plugins found there.
    call OpenMM_String_create(dir, '')
    call OpenMM_Platform_getDefaultPluginsDirectory(dir)
    call OpenMM_Platform_loadPluginsFromDirectory(dir)
    call OpenMM_String_destroy(dir)
    
    ! Create a System and Force objects for it. The System will take
    ! over ownership of the Forces; don't destroy them yourself.
    call OpenMM_System_create(system)
    call OpenMM_NonbondedForce_create(nonbond)
    call OpenMM_GBSAOBCForce_create(gbsa)
    
    ! Convert specific force types to generic OpenMM_Force so that we can
    ! add them to the OpenMM_System.
    call OpenMM_NonbondedForce_asForce(nonbond, force)
    call OpenMM_System_addForce(system, force)
    call OpenMM_GBSAOBCForce_asForce(gbsa, force)
    call OpenMM_System_addForce(system, force)

    ! Specify dielectrics for GBSA implicit solvation.
    call OpenMM_GBSAOBCForce_setSolventDielectric(gbsa, SolventDielectric)
    call OpenMM_GBSAOBCForce_setSoluteDielectric(gbsa, SoluteDielectric)
    
    ! Specify the atoms and their properties:
    !  (1) System needs to know the masses.
    !  (2) NonbondedForce needs charges,van der Waals properties (in MD units!).
    !  (3) GBSA needs charge, radius, and scale factor.
    !  (4) Collect default positions for initializing the simulation later.
    call OpenMM_Vec3Array_create(initialPosInNm, NumAtoms)
    do n=1,NumAtoms
        call OpenMM_System_addParticle(system, atoms(n)%mass)
    
        call OpenMM_NonbondedForce_addParticle(nonbond,                 &
                atoms(n)%charge,                                        &
                atoms(n)%vdwRadiusInAng  * OpenMM_NmPerAngstrom         &
                                         * OpenMM_SigmaPerVdwRadius,    &
                atoms(n)%vdwEnergyInKcal * OpenMM_KJPerKcal)
    
        call OpenMM_GBSAOBCForce_addParticle(gbsa,                      &
                atoms(n)%charge,                                        &
                atoms(n)%gbsaRadiusInAng * OpenMM_NmPerAngstrom,        &
                atoms(n)%gbsaScaleFactor)
    
        ! Sets initPos(n) = atoms(n)%initPos * nm/Angstrom.
        call OpenMM_Vec3Array_setScaled(initialPosInNm, n,              &
                                        atoms(n)%initPosInAng,          &
                                        OpenMM_NmPerAngstrom)
    end do
    
    ! Choose an Integrator for advancing time, and a Context connecting the
    ! System with the Integrator for simulation. Let the Context choose the
    ! best available Platform. Initialize the configuration from the default
    ! positions we collected above. Initial velocities will be zero but could
    ! have been set here.
    call OpenMM_LangevinIntegrator_create(langevin,                     &
                                          Temperature, FrictionInPerPs, &
                                          StepSizeInFs * OpenMM_PsPerFs)
    call OpenMM_LangevinIntegrator_asIntegrator(langevin, integrator)
    call OpenMM_Context_create(context, system, integrator)
    call OpenMM_Context_setPositions(context, initialPosInNm)

    ! Get the platform name to return.
    call OpenMM_Context_getPlatformName(context, platformName)
    
    ! Put the System, Integrator, and Context in the RuntimeObjects
    ! container and return an opaque reference to the container.
    call OpenMM_RuntimeObjects_create(omm)
    call OpenMM_RuntimeObjects_setSystem(omm, system)
    call OpenMM_RuntimeObjects_setIntegrator(omm, integrator)
    call OpenMM_RuntimeObjects_setContext(omm, context)
    ommHandle = transfer(omm, ommHandle)
END SUBROUTINE


!-------------------------------------------------------------------------------
!                     COPY STATE BACK TO CPU FROM OpenMM
!-------------------------------------------------------------------------------
SUBROUTINE myGetOpenMMState(ommHandle, timeInPs, energyInKcal)
    use OpenMM; use MyAtomInfo; implicit none
    integer*8, intent(in) :: ommHandle
    real*8, intent(out)   :: timeInPs, energyInKcal
    
    type (OpenMM_State)     state
    type (OpenMM_Vec3Array) posArray
    integer                 infoMask, n
    real*8                  posInNm(3)

    type (OpenMM_RuntimeObjects)  omm
    type (OpenMM_Context)         context

    omm = transfer(ommHandle, omm)
    call OpenMM_RuntimeObjects_getContext(omm, context)
    
    infoMask = OpenMM_State_Positions
    if (WantEnergy) then
        infoMask = infoMask + OpenMM_State_Velocities ! for KE (cheap)
        infoMask = infoMask + OpenMM_State_Energy     ! for PE (very expensive)
    end if
    ! Forces are also available (and cheap).
    
    ! Don't forget to destroy this State when you're done with it.
    call OpenMM_Context_createState(context, infoMask, state) 
    timeInPs = OpenMM_State_getTime(state) ! OpenMM time is in ps already.
    
    ! Positions are maintained as a Vec3Array inside the State. This will give
    ! us access, but don't destroy it yourself -- it will go away with the State.
    call OpenMM_State_getPositions(state, posArray)
    do n = 1, NumAtoms
        call OpenMM_Vec3Array_get(posArray, n, posInNm)
        call OpenMM_Vec3_scale(posInNm, OpenMM_AngstromsPerNm, atoms(n)%posInAng)
    end do
    
    energyInKcal = 0
    if (WantEnergy) then
        energyInKcal = (  OpenMM_State_getPotentialEnergy(state)   &
                        + OpenMM_State_getKineticEnergy(state))    &
                       * OpenMM_KcalPerKJ
    end if
    
    ! Clean up the State memory
    call OpenMM_State_destroy(state)
END SUBROUTINE


!-------------------------------------------------------------------------------
!                     TAKE MULTIPLE STEPS USING OpenMM
!-------------------------------------------------------------------------------
SUBROUTINE myStepWithOpenMM(ommHandle, numSteps)
    use OpenMM; implicit none
    integer*8, intent(in) :: ommHandle
    integer,   intent(in) :: numSteps

    type (OpenMM_RuntimeObjects) omm
    type (OpenMM_Integrator)     integrator
    omm = transfer(ommHandle, omm)
    call OpenMM_RuntimeObjects_getIntegrator(omm, integrator)
    
    call OpenMM_Integrator_step(integrator, numSteps)
END SUBROUTINE


!-------------------------------------------------------------------------------
!                      DEALLOCATE ALL OpenMM OBJECTS
!-------------------------------------------------------------------------------
SUBROUTINE myTerminateOpenMM(ommHandle)
    use OpenMM; implicit none
    integer*8, intent(in) :: ommHandle

    type (OpenMM_RuntimeObjects) omm
    omm = transfer(ommHandle, omm)

    call OpenMM_RuntimeObjects_destroy(omm)
END SUBROUTINE
