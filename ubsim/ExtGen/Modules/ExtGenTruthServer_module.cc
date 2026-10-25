////////////////////////////////////////////////////////////////////////
/// \file  ExtGenTruthServer_module.cc
/// \brief GENIE closure test (V2): plays the external generator by
///        writing the final states of full GENIE events (step A run with a
///        standard GENIE tune) as a served-event file (format in ExtGenIO.h).
///
/// Run in the same job as ExtGenRequestDumper on the same input, so that
/// req_id (the count of MCTruths in input order) is the same in both files.
/// Each record is rotated into the generator frame (neutrino along +z);
/// ExtGenMerge rotates it back, so with RandomAzimuth off the merged
/// MCTruth must reproduce GENIE's to rounding (ExtGenClosureCheck).
///
/// GENIE status codes: 1 -> 1, 11 (struck nucleon) -> 11, 15 (remnant)
/// -> 15; intermediate states (2, 3, 12, 13, 14, ...) are not written.
/// The primary lepton (MCNeutrino::Lepton()) is written first.
////////////////////////////////////////////////////////////////////////

#include <cstdio>
#include <memory>
#include <string>

#include "art/Framework/Core/EDAnalyzer.h"
#include "art/Framework/Core/ModuleMacros.h"
#include "art/Framework/Principal/Event.h"
#include "art/Framework/Principal/Handle.h"
#include "canvas/Utilities/Exception.h"
#include "canvas/Utilities/InputTag.h"
#include "fhiclcpp/types/Atom.h"
#include "messagefacility/MessageLogger/MessageLogger.h"

#include "nusimdata/SimulationBase/MCNeutrino.h"
#include "nusimdata/SimulationBase/MCTruth.h"

#include "ubsim/ExtGen/Modules/ExtGenIO.h"

namespace ubext {
  class ExtGenTruthServer;
}

class ubext::ExtGenTruthServer : public art::EDAnalyzer {
public:
  struct Config {
    using Name = fhicl::Name;
    using Comment = fhicl::Comment;

    fhicl::Atom<art::InputTag> InputTruth {
      Name("InputTruth"),
      Comment("full GENIE MCTruth collection (step A with a standard GENIE tune)"),
      "generator"
    };

    fhicl::Atom<std::string> OutputFile {
      Name("OutputFile"),
      Comment("served-event file to write"),
      "served_events.txt"
    };
  };
  using Parameters = art::EDAnalyzer::Table<Config>;

  explicit ExtGenTruthServer(Parameters const& config);

  ExtGenTruthServer(ExtGenTruthServer const&) = delete;
  ExtGenTruthServer(ExtGenTruthServer&&) = delete;
  ExtGenTruthServer& operator=(ExtGenTruthServer const&) = delete;
  ExtGenTruthServer& operator=(ExtGenTruthServer&&) = delete;

  void beginJob() override;
  void analyze(art::Event const& event) override;
  void endJob() override;

private:
  art::InputTag fInputTruth;
  std::string fOutputFile;

  struct FileCloser { void operator()(FILE* f) const { if (f) std::fclose(f); } };
  std::unique_ptr<FILE, FileCloser> fOut;
  long fNServed = 0;
};

//------------------------------------------------------------------------------
ubext::ExtGenTruthServer::ExtGenTruthServer(Parameters const& config)
  : EDAnalyzer(config)
  , fInputTruth(config().InputTruth())
  , fOutputFile(config().OutputFile())
{}

//------------------------------------------------------------------------------
void ubext::ExtGenTruthServer::beginJob()
{
  fOut.reset(std::fopen(fOutputFile.c_str(), "w"));
  if (!fOut) {
    throw art::Exception(art::errors::Configuration)
      << "ExtGenTruthServer: cannot open '" << fOutputFile << "' for writing\n";
  }
  std::fprintf(fOut.get(), "# extgen-served v1 generator=GENIE-closure input=%s\n",
               fInputTruth.encode().c_str());
  std::fprintf(fOut.get(), "# EVENT req_id E_GeV gen_proc simb_mode simb_inttype nparts\n"
                           "# P status pdg px py pz E   (GeV, neutrino along +z)\n");
}

//------------------------------------------------------------------------------
void ubext::ExtGenTruthServer::analyze(art::Event const& event)
{
  auto const& truths = event.getValidHandle<std::vector<simb::MCTruth>>(fInputTruth);

  for (size_t i = 0; i < truths->size(); ++i) {
    simb::MCTruth const& truth = truths->at(i);
    if (!truth.NeutrinoSet()) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenTruthServer: MCTruth " << i << " of event " << event.id()
        << " has no neutrino\n";
    }
    simb::MCNeutrino const& mcnu = truth.GetNeutrino();
    simb::MCParticle const& nu = mcnu.Nu();
    const TRotation toGen = GeneratorToDetector(nu.Momentum().Vect()).Inverse();

    ServedEvent ev;
    ev.reqId = fNServed++;
    ev.E = nu.E();
    ev.genProc = mcnu.Mode();
    ev.mode = mcnu.Mode();
    ev.intType = mcnu.InteractionType();

    auto add = [&](simb::MCParticle const& p) {
      ServedParticle sp;
      sp.status = p.StatusCode();
      sp.pdg = p.PdgCode();
      sp.p4 = Rotate(toGen, p.Momentum());
      ev.particles.push_back(sp);
    };

    // primary lepton first (same particle MCTruth::SetNeutrino chose)
    const int leptonId = mcnu.Lepton().TrackId();
    int iLepton = -1;
    for (int k = 0; k < truth.NParticles(); ++k) {
      simb::MCParticle const& p = truth.GetParticle(k);
      if (p.TrackId() == leptonId && p.StatusCode() == 1) { iLepton = k; break; }
    }
    if (iLepton < 0) {
      throw art::Exception(art::errors::LogicError)
        << "ExtGenTruthServer: no final-state primary lepton in MCTruth " << i
        << " of event " << event.id() << "\n";
    }
    add(truth.GetParticle(iLepton));
    for (int k = 0; k < truth.NParticles(); ++k) {
      simb::MCParticle const& p = truth.GetParticle(k);
      const int st = p.StatusCode();
      if (k == iLepton || (st != 1 && st != 11 && st != 15)) continue;
      add(p);
    }
    WriteServedEvent(fOut.get(), ev);
  }
}

//------------------------------------------------------------------------------
void ubext::ExtGenTruthServer::endJob()
{
  if (fOut && std::fflush(fOut.get()) != 0) {
    throw art::Exception(art::errors::EndJobFailure)
      << "ExtGenTruthServer: error writing '" << fOutputFile << "'\n";
  }
  fOut.reset();
  mf::LogInfo("ExtGenTruthServer") << "Wrote " << fNServed << " served events to "
                                   << fOutputFile;
}

DEFINE_ART_MODULE(ubext::ExtGenTruthServer)
