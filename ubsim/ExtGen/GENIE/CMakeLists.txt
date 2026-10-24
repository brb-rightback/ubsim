# GENIE algorithms that let GENIE's flux and geometry drivers choose
# interactions using the total cross sections of an external generator
# (GiBUU, ...). This is a plain GENIE plugin library, not an art module:
# GENIE instantiates the classes by name through their ROOT dictionary.

cet_add_compiler_flags( CXX -DHIDE_GENIE_LOG_XXX )

include_directories ( $ENV{LOG4CPP_INC} )

parse_ups_version( ${GENIE_VERSION} )
include_directories ( $ENV{GENIE_INC}/GENIE )
if( ${VMAJ} LESS 3 )
  message(FATAL_ERROR "ubsim/ExtGen requires GENIE v3 or later (found ${GENIE_VERSION})")
endif()

# GENIE v3 library list (as in ubsim/NGEM)
set (GENIE_LIB_LIST ${GFWMSG}
                    ${GFWREG}
                    ${GFWALG}
                    ${GFWINT}
                    ${GFWGHEP}
                    ${GFWNUM}
                    ${GSL}  # FWNUM relies on GSL
                    ${GFWUTL}
                    ${GFWPARDAT}
                    ${GFWEG}
                    ${GFWNTP}
                    ${GPHXSIG}
                    ${GPHPDF}
                    ${GPHNUCLST}
                    ${GPHCMN}
                    ${GPHDCY}
                    ${GPHHADTRANSP}
                    ${GPHHADNZ}
                    ${GPHDEEX}
                    ${GPHAMNGXS}
                    ${GPHAMNGEG}
                    ${GPHCHMXS}
                    ${GPHCOHXS}
                    ${GPHCOHEG}
                    ${GPHDISXS}
                    ${GPHDISEG}
                    ${GPHDFRCXS}
                    ${GPHDFRCEG}
                    ${GPHGLWRESXS}
                    ${GPHGLWRESEG}
                    ${GPHIBDXS}
                    ${GPHIBDEG}
                    ${GPHMNUCXS}
                    ${GPHMNUCEG}
                    ${GPHMEL}
                    ${GPHNUELXS}
                    ${GPHNUELEG}
                    ${GPHQELXS}
                    ${GPHQELEG}
                    ${GPHRESXS}
                    ${GPHRESEG}
                    ${GPHSTRXS}
                    ${GPHSTREG}
                    ${GPHNDCY}
                    ${GTLGEO}
                    ${GTLFLX} )

art_make_library( LIBRARY_NAME ubsim_ExtGen_GENIE
                  SOURCE ExtGenPXSec.cxx
                         ExtGenInteractionListGenerator.cxx
                  LIBRARIES ${GENIE_LIB_LIST}
                            ${ROOT_EGPYTHIA6}    # resolving genie run time reference, as in ubsim/NGEM
                            ${ROOT_BASIC_LIB_LIST}
                            ${ROOT_EG}
                            ${LOG4CPP}
                )

# Produces libubsim_ExtGen_GENIE_dict.so and its .rootmap, which is how
# GENIE (gROOT->GetClass) finds the classes at run time.
build_dictionary( NO_CHECK_CLASS_VERSION
                  DICTIONARY_LIBRARIES ubsim_ExtGen_GENIE
                                       ${GENIE_LIB_LIST}
                                       ${ROOT_BASIC_LIB_LIST}
                )

install_headers()
install_source()
