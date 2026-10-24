# GENIE configuration for the ExtGen tunes. Installed to <product>/<version>/gxml,
# which is deliberately NOT on FW_SEARCH_PATH: it contains overriding copies of
# GENIE's master_config.xml and EventGenerator.xml, so it must only be put on
# GXMLPATH by the ExtGen fcl files (GXMLPATH: "$UBSIM_DIR/gxml").

install( DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/
         DESTINATION ${product}/${version}/gxml
         FILES_MATCHING PATTERN "*.xml" )
