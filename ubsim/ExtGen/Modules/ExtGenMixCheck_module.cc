////////////////////////////////////////////////////////////////////////
/// \file  ExtGenMixCheck_module.cc
/// \brief Mixer test (V2(b)): checks that SimInfoMixer puts the merged
///        interactions onto the EXT events unchanged, and that every mixed
///        event is charged exactly the POT of the spills behind it.
///
/// Two modes, one per job:
///   Mode "ledger" (merge job): writes one line per merged event with its
///     POT (the event-level POTSummary that SubRunPOTInEvent makes, i.e. what
///     the mixer reads) and a fingerprint of its MCTruths, GTruths, MCFluxes
///     and BeamGateInfo. Also checks that every subrun number holds exactly
///     one event, which SimInfoMixer's per-event POT (AuxHasSeparateGenG4)
///     relies on: its POT map is keyed by subrun number alone.
///   Mode "check" (mixer job, with SelectEvents on the mixer path): the n-th
///     mixed event must have the fingerprint of the n-th ledger line (the
///     mixer reads the generator file in order), and the POTSummary the
///     mixer writes for each EXT subrun must equal the sum of the ledger POT
///     of the events mixed into it.
/// Any difference is printed and makes the job fail at endJob.
////////////////////////////////////////////////////////////////////////

#include <algorithm>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "art/Framework/Core/EDAnalyzer.h"
#include "art/Framework/Core/ModuleMacros.h"
#include "art/Framework/Principal/Event.h"
#include "art/Framework/Principal/Handle.h"
#include "art/Framework/Principal/SubRun.h"
#include "canvas/Persistency/Common/FindOne.h"
#include "canvas/Utilities/Exception.h"
#include "canvas/Utilities/InputTag.h"
#include "fhiclcpp/types/Atom.h"
#include "messagefacility/MessageLogger/MessageLogger.h"

#include "larcoreobj/SummaryData/POTSummary.h"
#include "lardataobj/Simulation/BeamGateInfo.h"
#include "nusimdata/SimulationBase/GTruth.h"
#include "nusimdata/SimulationBase/MCFlux.h"
#include "nusimdata/SimulationBase/MCNeutrino.h"
#include "nusimdata/SimulationBase/MCTruth.h"

namespace ubext {
  class ExtGenMixCheck;
}

class ubext::ExtGenMixCheck : public art::EDAnalyzer {
public:
  struct Config {
    using Name = fhicl::Name;
    using Comment = fhicl::Comment;

    fhicl::Atom<std::string> Mode {
      Name("Mode"),
      Comment("\"ledger\" (merge job) or \"check\" (mixer job)")
    };
    fhicl::Atom<art::InputTag> Truth {
      Name("Truth"),
      Comment("MCTruths and their GTruth/MCFlux/BeamGateInfo: \"generator::ExtGenMerge\" "
              "(ledger) or \"generator::SimInfoMixer\" (check)")
    };
    fhicl::Atom<art::InputTag> POT {
      Name("POT"),
      Comment("ledger: event-level POTSummary (\"potinevent:SubRunPOT\"); "
              "check: the mixer's subrun POTSummary (\"generator::SimInfoMixer\")")
    };
    fhicl::Atom<std::string> LedgerFile {
      Name("LedgerFile"),
      Comment("written in ledger mode, read in check mode"),
      "extgen_mix_ledger.txt"
    };
  };
  using Parameters = art::EDAnalyzer::Table<Config>;

  explicit ExtGenMixCheck(Parameters const& config);

  void analyze(art::Event const& event) override;
  void beginSubRun(art::SubRun const& sr) override;
  void endSubRun(art::SubRun const& sr) override;
  void endJob() override;

private:
  struct Entry {
    unsigned long idx = 0;
    unsigned int run = 0, subRun = 0, event = 0;
    double totpot = 0., totgoodpot = 0.;
    int totspills = 0, goodspills = 0;
    std::size_t nTruths = 0;
    double nuE = 0.;
    std::uint64_t hash = 0;
  };

  void fail(std::string const& what);
  bool Fingerprint(art::Event const& event, Entry& entry);
  void ReadLedger();

  bool fWrite;
  art::InputTag fTruth;
  art::InputTag fPOT;
  std::string fLedgerFile;

  // ledger mode
  FILE* fOut = nullptr;
  std::set<unsigned int> fSeenSubRuns;

  // check mode
  std::vector<Entry> fLedger;
  double fSR_pot = 0., fSR_goodpot = 0., fSR_spills = 0., fSR_goodspills = 0.;
  double fSumMixedPOT = 0., fSumLedgerPOT = 0., fAveragedPOT = 0.;
  unsigned long fNSkipped = 0;

  unsigned long fNEvents = 0, fNTruths = 0, fNSubRuns = 0, fNFailures = 0;
};

namespace {

  // FNV-1a over the text of the values: identical objects, identical hash.
  class Hasher {
  public:
    void add(double v)
    {
      char buf[32];
      std::snprintf(buf, sizeof buf, "%.17g ", v);
      add(buf);
    }
    void add(long v) { add(std::to_string(v) + " "); }
    void add(TLorentzVector const& v) { add(v.X()); add(v.Y()); add(v.Z()); add(v.T()); }
    void add(std::string const& s)
    {
      for (unsigned char c : s) { fH ^= c; fH *= 1099511628211ULL; }
    }
    std::uint64_t value() const { return fH; }
  private:
    std::uint64_t fH = 14695981039346656037ULL;
  };

} // namespace

//------------------------------------------------------------------------------
ubext::ExtGenMixCheck::ExtGenMixCheck(Parameters const& config)
  : EDAnalyzer(config)
  , fTruth(config().Truth())
  , fPOT(config().POT())
  , fLedgerFile(config().LedgerFile())
{
  const std::string mode = config().Mode();
  if (mode != "ledger" && mode != "check") {
    throw art::Exception(art::errors::Configuration)
      << "ExtGenMixCheck: Mode must be \"ledger\" or \"check\", not \"" << mode << "\"\n";
  }
  fWrite = (mode == "ledger");

  if (fWrite) {
    fOut = std::fopen(fLedgerFile.c_str(), "w");
    if (!fOut) {
      throw art::Exception(art::errors::Configuration)
        << "ExtGenMixCheck: cannot open ledger file '" << fLedgerFile << "' for writing\n";
    }
    std::fprintf(fOut, "# extgen-mix-ledger v1 truth=%s pot=%s\n",
                 fTruth.encode().c_str(), fPOT.encode().c_str());
    std::fprintf(fOut, "# idx run subrun event totpot totgoodpot totspills goodspills "
                       "ntruths nu_E hash\n");
  }
  else {
    ReadLedger();
  }
}

//------------------------------------------------------------------------------
void ubext::ExtGenMixCheck::ReadLedger()
{
  std::ifstream in(fLedgerFile);
  if (!in.is_open()) {
    throw art::Exception(art::errors::Configuration)
      << "ExtGenMixCheck: cannot open ledger file '" << fLedgerFile << "'\n";
  }
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream ss(line);
    Entry e;
    std::string pot, goodpot, nuE;
    if (!(ss >> e.idx >> e.run >> e.subRun >> e.event >> pot >> goodpot >> e.totspills >>
          e.goodspills >> e.nTruths >> nuE >> std::hex >> e.hash)) {
      throw art::Exception(art::errors::Configuration)
        << "ExtGenMixCheck: bad ledger line '" << line << "'\n";
    }
    e.totpot = std::stod(pot);  // strtod: exact for %.17g
    e.totgoodpot = std::stod(goodpot);
    e.nuE = std::stod(nuE);
    if (e.idx != fLedger.size()) {
      throw art::Exception(art::errors::Configuration)
        << "ExtGenMixCheck: ledger line " << e.idx << " out of order\n";
    }
    fLedger.push_back(e);
  }
  mf::LogInfo("ExtGenMixCheck") << "Read " << fLedger.size() << " events from " << fLedgerFile;
}

//------------------------------------------------------------------------------
void ubext::ExtGenMixCheck::fail(std::string const& what)
{
  ++fNFailures;
  if (fNFailures <= 50) mf::LogError("ExtGenMixCheck") << what;
}

//------------------------------------------------------------------------------
// Fills nTruths, nuE and hash; returns false if there are no MCTruths.
bool ubext::ExtGenMixCheck::Fingerprint(art::Event const& event, Entry& entry)
{
  auto const& truths = event.getValidHandle<std::vector<simb::MCTruth>>(fTruth);
  entry.nTruths = truths->size();
  if (truths->empty()) return false;

  const std::string ev = "event " + std::to_string(event.event()) + " (subrun " +
                         std::to_string(event.subRun()) + ")";
  art::FindOne<simb::GTruth> fg(truths, event, fTruth);
  art::FindOne<simb::MCFlux> ff(truths, event, fTruth);

  Hasher h;
  for (size_t i = 0; i < truths->size(); ++i) {
    ++fNTruths;
    simb::MCTruth const& t = truths->at(i);
    h.add(static_cast<long>(t.Origin()));
    h.add(static_cast<long>(t.NParticles()));
    for (int k = 0; k < t.NParticles(); ++k) {
      simb::MCParticle const& p = t.GetParticle(k);
      h.add(static_cast<long>(p.PdgCode()));
      h.add(static_cast<long>(p.StatusCode()));
      h.add(static_cast<long>(p.TrackId()));
      h.add(static_cast<long>(p.Mother()));
      h.add(p.Momentum());
      h.add(p.Position());
    }
    if (t.NeutrinoSet()) {
      simb::MCNeutrino const& n = t.GetNeutrino();
      h.add(static_cast<long>(n.CCNC()));
      h.add(static_cast<long>(n.Mode()));
      h.add(static_cast<long>(n.InteractionType()));
      h.add(static_cast<long>(n.Target()));
      h.add(static_cast<long>(n.HitNuc()));
      h.add(n.W()); h.add(n.X()); h.add(n.Y()); h.add(n.QSqr());
      if (i == 0) entry.nuE = n.Nu().E();
    }

    cet::maybe_ref<simb::GTruth const> g = fg.at(i);
    cet::maybe_ref<simb::MCFlux const> f = ff.at(i);
    if (!g.isValid() || !f.isValid()) {
      fail(ev + " truth " + std::to_string(i) + ": missing GTruth/MCFlux association");
      h.add("missing-assn");
      continue;
    }
    simb::GTruth const& gt = g.ref();
    h.add(static_cast<long>(gt.fGint));
    h.add(static_cast<long>(gt.fGscatter));
    h.add(static_cast<long>(gt.ftgtPDG));
    h.add(static_cast<long>(gt.fProbePDG));
    h.add(static_cast<long>(gt.fHitNucPDG));
    h.add(gt.fweight); h.add(gt.fXsec); h.add(gt.fDiffXsec);
    h.add(gt.fgQ2); h.add(gt.fgW); h.add(gt.fgX); h.add(gt.fgY);
    h.add(gt.fHitNucP4); h.add(gt.fFSleptonP4); h.add(gt.fFShadSystP4);
    h.add(gt.fProbeP4); h.add(gt.fVertex);

    simb::MCFlux const& fx = f.ref();
    h.add(static_cast<long>(fx.frun)); h.add(static_cast<long>(fx.fevtno));
    h.add(static_cast<long>(fx.fntype)); h.add(static_cast<long>(fx.fndecay));
    h.add(static_cast<long>(fx.fptype)); h.add(static_cast<long>(fx.ftptype));
    h.add(fx.fnenergy); h.add(fx.fnimpwt);
    h.add(fx.fvx); h.add(fx.fvy); h.add(fx.fvz);
    h.add(fx.fpdpx); h.add(fx.fpdpy); h.add(fx.fpdpz); h.add(fx.fppenergy);
    h.add(fx.fnwtnear); h.add(fx.fnwtfar);
    h.add(fx.fgenx); h.add(fx.fgeny); h.add(fx.fgenz);
    h.add(fx.fdk2gen); h.add(fx.fgen2vtx);
  }

  auto const& gates = event.getValidHandle<std::vector<sim::BeamGateInfo>>(fTruth);
  h.add(static_cast<long>(gates->size()));
  for (auto const& gate : *gates) {
    h.add(gate.Start()); h.add(gate.Width()); h.add(static_cast<long>(gate.BeamType()));
  }

  entry.hash = h.value();
  return true;
}

//------------------------------------------------------------------------------
void ubext::ExtGenMixCheck::analyze(art::Event const& event)
{
  Entry e;
  const bool any = Fingerprint(event, e);

  if (fWrite) {
    const std::string ev = "event " + std::to_string(event.event()) + " (subrun " +
                           std::to_string(event.subRun()) + ")";
    if (!any) fail(ev + ": no MCTruth");
    if (!fSeenSubRuns.insert(event.subRun()).second) {
      fail(ev + ": subrun number " + std::to_string(event.subRun()) +
           " holds more than one event; SimInfoMixer's per-event POT needs one event "
           "per subrun (step A: source.numberEventsInSubRun: 1)");
    }
    auto const& pot = event.getValidHandle<sumdata::POTSummary>(fPOT);
    e.idx = fNEvents;
    e.run = event.run();
    e.subRun = event.subRun();
    e.event = event.event();
    std::fprintf(fOut, "%lu %u %u %u %.17g %.17g %d %d %zu %.17g %016" PRIx64 "\n",
                 e.idx, e.run, e.subRun, e.event, pot->totpot, pot->totgoodpot,
                 pot->totspills, pot->goodspills, e.nTruths, e.nuE, e.hash);
    ++fNEvents;
    return;
  }

  // check mode: events the mixer had nothing left for carry empty collections
  if (!any) { ++fNSkipped; return; }

  const std::string ev = "mixed event " + std::to_string(event.event()) + " (subrun " +
                         std::to_string(event.subRun()) + ")";
  if (fNEvents >= fLedger.size()) {
    fail(ev + ": more mixed events than ledger lines (" + std::to_string(fLedger.size()) + ")");
    ++fNEvents;
    return;
  }
  Entry const& want = fLedger[fNEvents];
  if (e.nTruths != want.nTruths || e.hash != want.hash || e.nuE != want.nuE) {
    std::ostringstream os;
    os << ev << ": differs from generator event " << want.event << " (subrun " << want.subRun
       << ", ledger line " << want.idx << "): " << e.nTruths << "/" << want.nTruths
       << " MCTruths, nu E " << e.nuE << "/" << want.nuE;
    fail(os.str());
  }
  // the mixer's per-event POT, summed in the same order as the mixer does
  fSR_pot += want.totpot;
  fSR_goodpot += want.totgoodpot;
  fSR_spills += want.totspills;
  fSR_goodspills += want.goodspills;
  ++fNEvents;
}

//------------------------------------------------------------------------------
void ubext::ExtGenMixCheck::beginSubRun(art::SubRun const&)
{
  fSR_pot = fSR_goodpot = fSR_spills = fSR_goodspills = 0.;
}

//------------------------------------------------------------------------------
void ubext::ExtGenMixCheck::endSubRun(art::SubRun const& sr)
{
  if (fWrite) return;
  ++fNSubRuns;
  auto const& pot = sr.getValidHandle<sumdata::POTSummary>(fPOT);
  if (pot->totpot != fSR_pot || pot->totgoodpot != fSR_goodpot ||
      pot->totspills != static_cast<int>(fSR_spills) ||
      pot->goodspills != static_cast<int>(fSR_goodspills)) {
    std::ostringstream os;
    os.precision(17);
    os << "EXT run " << sr.run() << " subrun " << sr.subRun() << ": mixer POT " << pot->totpot
       << " (good " << pot->totgoodpot << ", spills " << pot->totspills << "/"
       << pot->goodspills << "), expected " << fSR_pot << " (good " << fSR_goodpot
       << ", spills " << fSR_spills << "/" << fSR_goodspills << ")";
    fail(os.str());
  }
  fSumMixedPOT += pot->totpot;
}

//------------------------------------------------------------------------------
void ubext::ExtGenMixCheck::endJob()
{
  if (fWrite) {
    const bool bad = std::fflush(fOut) != 0 || std::ferror(fOut);
    std::fclose(fOut);
    fOut = nullptr;
    if (bad) {
      throw art::Exception(art::errors::EndJobFailure)
        << "ExtGenMixCheck: error writing ledger file '" << fLedgerFile << "'\n";
    }
    mf::LogInfo("ExtGenMixCheck")
      << "Mix ledger: " << fNEvents << " events, " << fNTruths << " interactions written to "
      << fLedgerFile << "\n  failures: " << fNFailures;
  }
  else {
    const unsigned long used = std::min<unsigned long>(fNEvents, fLedger.size());
    for (unsigned long i = 0; i < used; ++i) fSumLedgerPOT += fLedger[i].totpot;
    // what SimInfoMixer's default mode (POT of the file / events in it) would charge
    for (unsigned long i = 0; i < used; ++i) fAveragedPOT += fLedger[i].totpot / fLedger.size();
    std::ostringstream os;
    os.precision(10);
    os << "Mix check: " << fNEvents << " mixed events (" << fNTruths << " interactions) "
       << "compared with " << fLedger.size() << " generator events; " << fNSkipped
       << " EXT events left without an interaction; " << fNSubRuns << " EXT subruns.\n"
       << "  POT written by the mixer:            " << fSumMixedPOT << "\n"
       << "  POT of the generator events mixed:   " << fSumLedgerPOT << "\n"
       << "  (default mixer mode would give:      " << fAveragedPOT << ")\n"
       << "  failures: " << fNFailures;
    mf::LogInfo("ExtGenMixCheck") << os.str();
  }
  if (fNFailures != 0) {
    throw art::Exception(art::errors::EndJobFailure)
      << "ExtGenMixCheck: " << fNFailures << " failures (first 50 printed above)\n";
  }
}

DEFINE_ART_MODULE(ubext::ExtGenMixCheck)
