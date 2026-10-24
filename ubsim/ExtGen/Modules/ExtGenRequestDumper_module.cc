////////////////////////////////////////////////////////////////////////
/// \file  ExtGenRequestDumper_module.cc
/// \brief Writes the interactions chosen by GENIE in step A (neutrino and
///        target only, ExtGen tune) as "requests" for an external
///        generator: one text line per MCTruth.
///
/// Follows the conventions of larsim's DumpMCTruth (InputTruth,
/// OutputCategory), but writes a machine-readable table with the neutrino
/// energy at full double precision, so that the external generator's events
/// can be matched back to their requests exactly (see the file format in
/// GIBUU_GENIE_INTEGRATION_PLAN.md, section 6.1):
///
///   # extgen-requests v1 tune=... spline=... seed=... beam=... process=...
///   # req_id run subrun event truth_idx nu_pdg ccnc tgt_pdg E_GeV vx vy vz t dx dy dz
///
/// E_GeV and the direction cosines are written with %.17g (exact round
/// trip); vertex [cm] and time [ns] with %.10g. req_id counts the requests
/// of the job from 0, in input order.
///
/// Every request is checked against its GTruth (same probe, target and
/// current; not the energy, since GTruth's fProbeP4 is in the hit-nucleon
/// rest frame) and must be a weak CC/NC interaction of a neutrino on a
/// nucleus or free nucleon; anything else is a fatal error.
////////////////////////////////////////////////////////////////////////

#include <cmath>
#include <cstdio>
#include <memory>
#include <string>

#include "art/Framework/Core/EDAnalyzer.h"
#include "art/Framework/Core/ModuleMacros.h"
#include "art/Framework/Principal/Event.h"
#include "art/Framework/Principal/Handle.h"
#include "art/Framework/Principal/Provenance.h"
#include "canvas/Persistency/Common/FindOne.h"
#include "canvas/Utilities/Exception.h"
#include "canvas/Utilities/InputTag.h"
#include "fhiclcpp/ParameterSet.h"
#include "fhiclcpp/types/Atom.h"
#include "messagefacility/MessageLogger/MessageLogger.h"

#include "nusimdata/SimulationBase/GTruth.h"
#include "nusimdata/SimulationBase/MCNeutrino.h"
#include "nusimdata/SimulationBase/MCTruth.h"

namespace ubext {
  class ExtGenRequestDumper;
}

class ubext::ExtGenRequestDumper : public art::EDAnalyzer {
public:
  struct Config {
    using Name = fhicl::Name;
    using Comment = fhicl::Comment;

    fhicl::Atom<art::InputTag> InputTruth {
      Name("InputTruth"),
      Comment("step-A MCTruth collection (GENIEGen with the ExtGen tune)"),
      "generator"
    };

    fhicl::Atom<std::string> OutputFile {
      Name("OutputFile"),
      Comment("request file to write"),
      "requests.txt"
    };

    fhicl::Atom<std::string> OutputCategory {
      Name("OutputCategory"),
      Comment("message facility category for the summary"),
      "ExtGenRequestDumper"
    };
  };
  using Parameters = art::EDAnalyzer::Table<Config>;

  explicit ExtGenRequestDumper(Parameters const& config);

  ExtGenRequestDumper(ExtGenRequestDumper const&) = delete;
  ExtGenRequestDumper(ExtGenRequestDumper&&) = delete;
  ExtGenRequestDumper& operator=(ExtGenRequestDumper const&) = delete;
  ExtGenRequestDumper& operator=(ExtGenRequestDumper&&) = delete;

  void beginJob() override;
  void analyze(art::Event const& event) override;
  void endJob() override;

private:
  void writeHeader(art::Provenance const& prov);

  art::InputTag fInputTruth;
  std::string fOutputFile;
  std::string fOutputCategory;

  struct FileCloser { void operator()(FILE* f) const { if (f) std::fclose(f); } };
  std::unique_ptr<FILE, FileCloser> fOut;
  bool fHeaderWritten = false;
  unsigned long fNRequests = 0;
  unsigned long fNEvents = 0;
};

//------------------------------------------------------------------------------
ubext::ExtGenRequestDumper::ExtGenRequestDumper(Parameters const& config)
  : EDAnalyzer(config)
  , fInputTruth(config().InputTruth())
  , fOutputFile(config().OutputFile())
  , fOutputCategory(config().OutputCategory())
{}

//------------------------------------------------------------------------------
void ubext::ExtGenRequestDumper::beginJob()
{
  fOut.reset(std::fopen(fOutputFile.c_str(), "w"));
  if (!fOut) {
    throw art::Exception(art::errors::Configuration)
      << "ExtGenRequestDumper: cannot open '" << fOutputFile << "' for writing\n";
  }
}

//------------------------------------------------------------------------------
void ubext::ExtGenRequestDumper::writeHeader(art::Provenance const& prov)
{
  // Record how the requests were made, from the step-A generator's own
  // configuration.
  fhicl::ParameterSet const& pset = prov.parameterSet();
  std::string seed = "service";
  int iseed = 0;
  unsigned int useed = 0;
  if (pset.get_if_present("RandomSeed", iseed)) seed = std::to_string(iseed);
  else if (pset.get_if_present("Seed", useed)) seed = std::to_string(useed);

  std::fprintf(fOut.get(),
               "# extgen-requests v1 tune=%s spline=%s seed=%s beam=%s process=%s\n",
               pset.get<std::string>("TuneName", "?").c_str(),
               pset.get<std::string>("XSecTable", "?").c_str(),
               seed.c_str(),
               pset.get<std::string>("BeamName", "?").c_str(),
               prov.processName().c_str());
  std::fprintf(fOut.get(),
               "# req_id run subrun event truth_idx nu_pdg ccnc tgt_pdg E_GeV"
               " vx vy vz t dx dy dz\n");
  fHeaderWritten = true;
}

//------------------------------------------------------------------------------
void ubext::ExtGenRequestDumper::analyze(art::Event const& event)
{
  auto const& truthHandle = event.getValidHandle<std::vector<simb::MCTruth>>(fInputTruth);
  art::FindOne<simb::GTruth> gtruths(truthHandle, event, fInputTruth);

  if (!fHeaderWritten) writeHeader(*truthHandle.provenance());
  ++fNEvents;

  for (size_t i = 0; i < truthHandle->size(); ++i) {
    simb::MCTruth const& truth = truthHandle->at(i);

    if (!truth.NeutrinoSet()) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenRequestDumper: MCTruth " << i << " of event " << event.id()
        << " has no neutrino\n";
    }
    simb::MCNeutrino const& mcnu = truth.GetNeutrino();
    simb::MCParticle const& nu = mcnu.Nu();
    const int nuPdg = nu.PdgCode();
    const int ccnc = mcnu.CCNC();
    const int tgtPdg = mcnu.Target();
    const double E = nu.E();

    if (std::abs(nuPdg) != 12 && std::abs(nuPdg) != 14 && std::abs(nuPdg) != 16) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenRequestDumper: probe " << nuPdg << " in event " << event.id()
        << " is not a neutrino\n";
    }
    if (ccnc != simb::kCC && ccnc != simb::kNC) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenRequestDumper: bad CCNC " << ccnc << " in event " << event.id() << "\n";
    }
    if (tgtPdg / 1000000000 != 1) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenRequestDumper: target " << tgtPdg << " in event " << event.id()
        << " is not a nucleus/nucleon ion code\n";
    }

    // GTruth must describe the same request.
    cet::maybe_ref<simb::GTruth const> gref = gtruths.at(i);
    if (!gref.isValid()) {
      throw art::Exception(art::errors::ProductNotFound)
        << "ExtGenRequestDumper: no GTruth associated with MCTruth " << i
        << " of event " << event.id() << "\n";
    }
    simb::GTruth const& gt = gref.ref();
    // genie::InteractionType_t: kIntWeakCC = 2, kIntWeakNC = 3
    const int gtCurrent = (gt.fGint == 2) ? simb::kCC : (gt.fGint == 3) ? simb::kNC : -1;
    if (gt.fProbePDG != nuPdg || gt.ftgtPDG != tgtPdg || gtCurrent != ccnc) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenRequestDumper: MCTruth and GTruth differ in event " << event.id()
        << " (truth " << i << "): probe " << nuPdg << "/" << gt.fProbePDG
        << ", target " << tgtPdg << "/" << gt.ftgtPDG
        << ", ccnc " << ccnc << "/" << gtCurrent << " (Gint " << gt.fGint << ")\n";
    }

    // |p| from the 3-momentum, not MCParticle::P() = sqrt(E^2 - m^2): the
    // flux 4-vectors are not exactly massless (single precision in gsimple),
    // so E and |p| differ at the 1e-8 level.
    const double p = nu.Momentum().Vect().Mag();
    std::fprintf(fOut.get(),
                 "%lu %u %u %u %zu %d %s %d %.17g %.10g %.10g %.10g %.10g %.17g %.17g %.17g\n",
                 fNRequests, event.run(), event.subRun(), event.event(), i,
                 nuPdg, (ccnc == simb::kCC ? "CC" : "NC"), tgtPdg, E,
                 nu.Vx(), nu.Vy(), nu.Vz(), nu.T(),
                 nu.Px() / p, nu.Py() / p, nu.Pz() / p);
    ++fNRequests;
  }
}

//------------------------------------------------------------------------------
void ubext::ExtGenRequestDumper::endJob()
{
  if (fOut && std::fflush(fOut.get()) != 0) {
    throw art::Exception(art::errors::EndJobFailure)
      << "ExtGenRequestDumper: error writing '" << fOutputFile << "'\n";
  }
  fOut.reset();
  mf::LogInfo(fOutputCategory) << "Wrote " << fNRequests << " requests from "
                               << fNEvents << " events to " << fOutputFile;
}

DEFINE_ART_MODULE(ubext::ExtGenRequestDumper)
