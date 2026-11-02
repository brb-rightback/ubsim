////////////////////////////////////////////////////////////////////////
/// \file  ExtGenInteractionListGenerator.cxx
/// \brief See ExtGenInteractionListGenerator.h
////////////////////////////////////////////////////////////////////////

#include <iostream>

#include "Framework/EventGen/InteractionList.h"
#include "Framework/Interaction/Interaction.h"
#include "Framework/Messenger/Messenger.h"
#include "Framework/ParticleData/PDGCodes.h"
#include "Framework/ParticleData/PDGUtils.h"
#include "Framework/Utils/XSecSplineList.h"

#include "ubsim/ExtGen/GENIE/ExtGenInteractionListGenerator.h"

namespace genie {
namespace ubext {

//____________________________________________________________________________
ExtGenInteractionListGenerator::ExtGenInteractionListGenerator() :
  InteractionListGeneratorI("genie::ubext::ExtGenInteractionListGenerator")
{
}
//____________________________________________________________________________
ExtGenInteractionListGenerator::ExtGenInteractionListGenerator(std::string config) :
  InteractionListGeneratorI("genie::ubext::ExtGenInteractionListGenerator", config)
{
}
//____________________________________________________________________________
ExtGenInteractionListGenerator::~ExtGenInteractionListGenerator()
{
}
//____________________________________________________________________________
InteractionList* ExtGenInteractionListGenerator::CreateInteractionList(
  const InitialState& init) const
{
  if (!pdg::IsNeutralLepton(init.ProbePdg())) {
    LOG("ExtGenILst", pWARN) << "Not a neutrino probe: " << init.ProbePdg();
    return 0;
  }

  InteractionList* intlist = new InteractionList;

  for (InteractionType_t type : {kIntWeakCC, kIntWeakNC}) {
    if ((type == kIntWeakCC && !fIsCC) || (type == kIntWeakNC && !fIsNC)) continue;

    Interaction* interaction = new Interaction(init, ProcessInfo(kScNull, type));
    if (interaction->InitState().Tgt().IsFreeNucleon()) {
      interaction->InitStatePtr()->TgtPtr()->SetHitNucPdg(
        interaction->InitState().Tgt().Z() == 1 ? kPdgProton : kPdgNeutron);
    }
    intlist->push_back(interaction);

    // GENIE refuses to use splines for an initial state if any of its
    // interactions lacks one, and in production mode its warning is not
    // printed, so report the exact missing key here.
    const std::string key = "genie::ubext::ExtGenPXSec/Default/" + interaction->AsString();
    XSecSplineList* xsl = XSecSplineList::Instance();
    if (!xsl->SplineExists(key)) {
      std::cerr << "genie::ubext::ExtGenInteractionListGenerator: no spline '" << key
                << "' for tune '" << xsl->CurrentTune() << "' (" << xsl->NSplines()
                << " splines loaded for this tune)" << std::endl;
    }
  }

  return intlist;
}
//____________________________________________________________________________
void ExtGenInteractionListGenerator::Configure(const Registry& config)
{
  Algorithm::Configure(config);
  this->LoadConfigData();
}
//____________________________________________________________________________
void ExtGenInteractionListGenerator::Configure(std::string config)
{
  Algorithm::Configure(config);
  this->LoadConfigData();
}
//____________________________________________________________________________
void ExtGenInteractionListGenerator::LoadConfigData()
{
  GetParamDef("is-CC", fIsCC, true);
  GetParamDef("is-NC", fIsNC, true);
}

} // namespace ubext
} // namespace genie
