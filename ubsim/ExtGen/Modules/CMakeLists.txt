# art modules of the ExtGen chain.
art_make( BASENAME_ONLY
          MODULE_LIBRARIES nusimdata_SimulationBase
                           ${ART_FRAMEWORK_CORE}
                           ${ART_FRAMEWORK_PRINCIPAL}
                           art_Persistency_Common canvas
                           art_Persistency_Provenance canvas
                           art_Utilities canvas
                           ${MF_MESSAGELOGGER}
                           ${FHICLCPP}
                           cetlib cetlib_except
                           ${ROOT_BASIC_LIB_LIST}
        )

install_source()
