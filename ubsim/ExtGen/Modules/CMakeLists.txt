# art modules of the ExtGen chain, and the library ubsim_ExtGen_Modules
# (ExtGenIO: request/served-event files and frame rotation) they share.
include_directories ( $ENV{DK2NU_INC} )

art_make( BASENAME_ONLY
          LIB_LIBRARIES cetlib_except
                        ${ROOT_BASIC_LIB_LIST}
                        ${ROOT_PHYSICS}
          MODULE_LIBRARIES ubsim_ExtGen_Modules
                           nusimdata_SimulationBase
                           lardataobj_Simulation
                           larcoreobj_SummaryData
                           lardata_Utilities
                           nutools_RandomUtils_NuRandomService_service
                           ${DK2NU_TREE}
                           ${ART_FRAMEWORK_CORE}
                           ${ART_FRAMEWORK_PRINCIPAL}
                           ${ART_FRAMEWORK_SERVICES_REGISTRY}
                           ${ART_FRAMEWORK_SERVICES_OPTIONAL_RANDOMNUMBERGENERATOR_SERVICE}
                           art_Persistency_Common canvas
                           art_Persistency_Provenance canvas
                           art_Utilities canvas
                           ${MF_MESSAGELOGGER}
                           ${FHICLCPP}
                           cetlib cetlib_except
                           ${CLHEP}
                           ${ROOT_BASIC_LIB_LIST}
                           ${ROOT_PHYSICS}
        )

install_headers()
install_source()
