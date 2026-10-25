////////////////////////////////////////////////////////////////////////
/// \file  extgen_gibuu_convert.cc
/// \brief Step C of the ExtGen chain for GiBUU: turns the output of GiBUU
///        runs in request mode into served_events.txt and trial_stats.txt.
///
///   extgen_gibuu_convert -r requests.txt -o served_events.txt
///                        -t trial_stats.txt [--allow-missing] GROUPDIR...
///
/// Each GROUPDIR is one GiBUU run (one target, flavour and current) and holds
///   EventOutput.Pert.hepmc3      NuHepMC output, events tagged with
///                                "A 0 uboone.RequestID"
///   uboone_request_stats.dat     per-request trial statistics (nuRequests)
///
/// Checks, any failure is fatal:
///   - every event carries a request id that its group's statistics list as
///     served, each request is served exactly once, and (unless
///     --allow-missing) every request of requests.txt is served;
///   - the request's energy is exactly the one GiBUU was given (statistics)
///     and matches the event's beam particle to 1e-14; the beam is along +z;
///   - neutrino flavour, target (A, Z) and CC/NC agree with the request;
///   - the event has exactly one primary lepton, of the right flavour.
///
/// served_events.txt (format in ExtGenIO.h), per event:
///   gen_proc = GiBUU channel ID (GiBUU.ChannelID), simb mode and interaction
///   type from the NuHepMC process ID (see MapProcID); particles: struck
///   nucleon (NuHepMC status 21) as status 11, the primary lepton, then the
///   other final-state particles: status 1 (escaped) as 1, status 23 (did not
///   leave the nucleus) as 2, i.e. not tracked. Beam, target and the dummy
///   remnant (status 4, 20, 22) are not written. Momenta as GiBUU writes them
///   (target rest frame, neutrino along +z); E_GeV is the request's.
///
/// trial_stats.txt, per request (w = total cross section of one GiBUU trial,
/// 1e-38 cm^2 per nucleus, i.e. GiBUU's per-nucleon value times A):
///   req_id tgt_pdg nu_pdg ccnc E_GeV n_trials sum_w sum_w2 max_w n_dropped
/// sum_w / n_trials estimates sigma(E) for the in-job check against the
/// splines (V4).
////////////////////////////////////////////////////////////////////////

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "cetlib_except/exception.h"

#include "nusimdata/SimulationBase/MCNeutrino.h"

#include "ubsim/ExtGen/Modules/ExtGenIO.h"

namespace {

  const char* const kProg = "extgen_gibuu_convert";

  struct Stat {
    long reqId = -1;
    double E = 0., max = 0.;
    long long nTrials = 0;
    double sumW = 0., sumW2 = 0., maxW = 0.;
    long nDropped = 0;
    long run = 0, firstEvent = 0;
  };

  struct GroupStats {
    int A = 0, Z = 0;
    std::map<long, Stat> stats;  // by req_id
  };

  struct NuParticle {
    int pdg = 0, status = 0;
    double px = 0., py = 0., pz = 0., e = 0.;
  };

  struct NuEvent {
    long reqId = -1;
    long channel = -1, procId = -1, run = -1;
    int tgtPdg = 0;
    NuParticle beam;
    std::vector<NuParticle> parts;  // statuses 1, 21, 23 in file order
    unsigned long line = 0;
  };

  std::string Where(std::string const& path, unsigned long line)
  {
    return path + ":" + std::to_string(line);
  }

  double ToDouble(std::string const& s, std::string const& where)
  {
    char* end = nullptr;
    const double v = std::strtod(s.c_str(), &end);
    if (s.empty() || *end != '\0') {
      throw cet::exception(kProg) << where << ": bad number '" << s << "'\n";
    }
    return v;
  }

  // NuHepMC process IDs of GiBUU (header NuHepMC.ProcessInfo):
  //   200/250 QE, 300/350 2p2h QE, 301/351 2p2h Delta, 400/450 Delta,
  //   401/451 other resonances, 500/550 and 501/551 1pi background,
  //   502/552 2pi background, 600/650 DIS (+50: NC).
  // Modes as in the earlier GiBUU HepMC production; the non-resonant pion
  // backgrounds are DIS, as GENIE labels non-resonant pion production.
  // Interaction types follow GENIE2ART (kNuanceOffset + GENIE's NUANCE code):
  // QE 1001/1002, DIS 1091/1092; MEC and resonances 1000, which GENIE also
  // writes for MEC and for resonance events outside its single-pion channels
  // (GiBUU's output has no pre-FSI resonance decay to classify them).
  void MapProcID(long procId, bool& isCC, int& mode, int& intType, std::string const& where)
  {
    if (procId <= 0) {
      throw cet::exception(kProg) << where << ": unknown NuHepMC process ID " << procId << "\n";
    }
    isCC = (procId % 100) < 50;
    switch (procId / 100) {
    case 2: mode = simb::kQE;  intType = isCC ? simb::kCCQE : simb::kNCQE; break;
    case 3: mode = simb::kMEC; intType = simb::kNuanceOffset; break;
    case 4: mode = simb::kRes; intType = simb::kNuanceOffset; break;
    case 5:
    case 6: mode = simb::kDIS; intType = isCC ? simb::kCCDIS : simb::kNCDIS; break;
    default:
      throw cet::exception(kProg) << where << ": unknown NuHepMC process ID " << procId << "\n";
    }
  }

  //----------------------------------------------------------------------------
  GroupStats ReadStats(std::string const& path)
  {
    std::ifstream in(path);
    if (!in.is_open()) throw cet::exception(kProg) << "cannot open " << path << "\n";
    GroupStats g;
    std::string line;
    unsigned long lineno = 0;
    bool header = false;
    while (std::getline(in, line)) {
      ++lineno;
      if (line.empty()) continue;
      if (line[0] == '#') {
        if (line.rfind("# uboone-request-stats v1", 0) == 0) {
          header = true;
          int mode = 0;
          if (std::sscanf(line.c_str(), "# uboone-request-stats v1 mode=%d A=%d Z=%d", &mode,
                          &g.A, &g.Z) != 3) {
            throw cet::exception(kProg) << Where(path, lineno) << ": bad header\n";
          }
          if (mode != 1) {
            throw cet::exception(kProg) << path << ": request mode " << mode
                                        << ", expected 1 (serve)\n";
          }
        }
        continue;
      }
      std::istringstream ss(line);
      std::vector<std::string> c;
      std::string t;
      while (ss >> t) c.push_back(t);
      if (c.size() != 10) {
        throw cet::exception(kProg) << Where(path, lineno) << ": " << c.size()
                                    << " columns, expected 10\n";
      }
      const std::string w = Where(path, lineno);
      Stat s;
      s.reqId = std::stol(c[0]);
      s.E = ToDouble(c[1], w);
      s.max = ToDouble(c[2], w);
      s.nTrials = std::stoll(c[3]);
      s.sumW = ToDouble(c[4], w);
      s.sumW2 = ToDouble(c[5], w);
      s.maxW = ToDouble(c[6], w);
      s.nDropped = std::stol(c[7]);
      s.run = std::stol(c[8]);
      s.firstEvent = std::stol(c[9]);
      if (!g.stats.emplace(s.reqId, s).second) {
        throw cet::exception(kProg) << w << ": request " << s.reqId << " listed twice\n";
      }
    }
    if (!header) throw cet::exception(kProg) << path << ": no uboone-request-stats header\n";
    return g;
  }

  //----------------------------------------------------------------------------
  std::vector<NuEvent> ReadNuHepMC(std::string const& path)
  {
    std::ifstream in(path);
    if (!in.is_open()) throw cet::exception(kProg) << "cannot open " << path << "\n";
    std::vector<NuEvent> events;
    std::string line;
    unsigned long lineno = 0;
    bool inEvent = false, seenEnd = false;
    while (std::getline(in, line)) {
      ++lineno;
      if (line.empty()) continue;
      std::istringstream ss(line);
      std::string tag;
      ss >> tag;
      const std::string w = Where(path, lineno);
      if (tag == "E") {
        events.emplace_back();
        events.back().line = lineno;
        inEvent = true;
      }
      else if (tag == "HepMC::Asciiv3-END_EVENT_LISTING") {
        seenEnd = true;
        break;
      }
      else if (!inEvent) {
        continue;  // file header
      }
      else if (tag == "A") {
        int id;
        std::string key, value;
        ss >> id >> key >> value;
        if (id != 0) continue;
        NuEvent& ev = events.back();
        if (key == "uboone.RequestID") ev.reqId = std::stol(value);
        else if (key == "GiBUU.ChannelID") ev.channel = std::stol(value);
        else if (key == "ProcID") ev.procId = std::stol(value);
        else if (key == "GiBUU.Run") ev.run = std::stol(value);
      }
      else if (tag == "P") {
        std::string id, mother, pdg, px, py, pz, e, m, status;
        if (!(ss >> id >> mother >> pdg >> px >> py >> pz >> e >> m >> status)) {
          throw cet::exception(kProg) << w << ": bad P line\n";
        }
        NuParticle p;
        p.pdg = std::stoi(pdg);
        p.status = std::stoi(status);
        p.px = ToDouble(px, w);
        p.py = ToDouble(py, w);
        p.pz = ToDouble(pz, w);
        p.e = ToDouble(e, w);
        NuEvent& ev = events.back();
        switch (p.status) {
        case 4:
          if (ev.beam.pdg != 0) throw cet::exception(kProg) << w << ": second beam particle\n";
          ev.beam = p;
          break;
        case 20: ev.tgtPdg = p.pdg; break;
        case 22: break;  // dummy remnant
        case 1:
        case 21:
        case 23: ev.parts.push_back(p); break;
        default:
          throw cet::exception(kProg) << w << ": unexpected particle status " << p.status << "\n";
        }
      }
    }
    if (!seenEnd) {
      throw cet::exception(kProg) << path
                                  << ": no END_EVENT_LISTING (GiBUU did not finish?)\n";
    }
    return events;
  }

  //----------------------------------------------------------------------------
  // The event of one request, checked against it.
  ubext::ServedEvent MakeServed(NuEvent const& ev, ubext::Request const& req, Stat const& st,
                                GroupStats const& g, std::string const& where)
  {
    // target: GiBUU writes 2212/2112 for A = 1
    const int tgt = (g.A == 1) ? 1000000000 + g.Z * 10000 + 10 : 1000000000 + g.Z * 10000 + g.A * 10;
    if (tgt != req.tgtPdg) {
      throw cet::exception(kProg) << where << ": GiBUU target A=" << g.A << " Z=" << g.Z
                                  << ", request " << req.reqId << " has " << req.tgtPdg << "\n";
    }
    const int evTgt = (g.A == 1) ? (g.Z == 1 ? 2212 : 2112) : tgt;
    if (ev.tgtPdg != evTgt) {
      throw cet::exception(kProg) << where << ": event target " << ev.tgtPdg << ", expected "
                                  << evTgt << "\n";
    }
    if (st.E != req.E) {
      throw cet::exception(kProg) << where << ": GiBUU ran request " << req.reqId << " at E="
                                  << st.E << ", requested " << req.E << "\n";
    }
    if (ev.beam.pdg != req.nuPdg) {
      throw cet::exception(kProg) << where << ": beam " << ev.beam.pdg << ", request has "
                                  << req.nuPdg << "\n";
    }
    if (std::abs(ev.beam.e / req.E - 1.) > 1e-14 || std::abs(ev.beam.px) > 1e-12 * req.E ||
        std::abs(ev.beam.py) > 1e-12 * req.E || ev.beam.pz <= 0.) {
      char buf[200];
      std::snprintf(buf, sizeof buf, "beam (%.17g, %.17g, %.17g; %.17g), request E %.17g",
                    ev.beam.px, ev.beam.py, ev.beam.pz, ev.beam.e, req.E);
      throw cet::exception(kProg) << where << ": " << buf << "\n";
    }
    if (st.run != ev.run) {
      throw cet::exception(kProg) << where << ": event from run " << ev.run
                                  << ", statistics say run " << st.run << "\n";
    }

    bool isCC = false;
    int mode = 0, intType = 0;
    MapProcID(ev.procId, isCC, mode, intType, where);
    if (isCC != req.isCC) {
      throw cet::exception(kProg) << where << ": process ID " << ev.procId << " but request "
                                  << req.reqId << " is " << (req.isCC ? "CC" : "NC") << "\n";
    }
    if (ev.channel < 0) throw cet::exception(kProg) << where << ": no GiBUU.ChannelID\n";

    const int sign = (req.nuPdg > 0) ? 1 : -1;
    const int leptonPdg = isCC ? req.nuPdg - sign : req.nuPdg;

    ubext::ServedEvent out;
    out.reqId = req.reqId;
    out.E = req.E;
    out.genProc = ev.channel;
    out.mode = mode;
    out.intType = intType;

    // struck nucleon, then the primary lepton (GiBUU writes it as the first
    // status-1 particle), then the rest
    int nHit = 0;
    for (auto const& p : ev.parts) {
      if (p.status != 21) continue;
      if (++nHit > 1) throw cet::exception(kProg) << where << ": two struck nucleons\n";
      out.particles.push_back({11, p.pdg, TLorentzVector(p.px, p.py, p.pz, p.e)});
    }
    bool lepton = false;
    for (auto const& p : ev.parts) {
      if (p.status == 21) continue;
      if (!lepton) {
        if (p.status != 1 || p.pdg != leptonPdg) {
          throw cet::exception(kProg) << where << ": first final-state particle is " << p.pdg
                                      << " (status " << p.status << "), expected lepton "
                                      << leptonPdg << "\n";
        }
        lepton = true;
        out.particles.push_back({1, p.pdg, TLorentzVector(p.px, p.py, p.pz, p.e)});
        continue;
      }
      out.particles.push_back({p.status == 1 ? 1 : 2, p.pdg, TLorentzVector(p.px, p.py, p.pz, p.e)});
    }
    if (!lepton) throw cet::exception(kProg) << where << ": no primary lepton\n";
    return out;
  }

  void Usage()
  {
    std::cerr << "usage: " << kProg << " -r requests.txt -o served_events.txt -t trial_stats.txt"
              << " [--allow-missing] GROUPDIR...\n";
  }

} // namespace

//------------------------------------------------------------------------------
int main(int argc, char** argv)
{
  std::string reqPath, outPath, statPath;
  bool allowMissing = false;
  std::vector<std::string> groups;
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if ((a == "-r" || a == "-o" || a == "-t") && i + 1 < argc) {
      (a == "-r" ? reqPath : a == "-o" ? outPath : statPath) = argv[++i];
    }
    else if (a == "--allow-missing") allowMissing = true;
    else if (!a.empty() && a[0] == '-') { Usage(); return 2; }
    else groups.push_back(a);
  }
  if (reqPath.empty() || outPath.empty() || statPath.empty() || groups.empty()) {
    Usage();
    return 2;
  }

  try {
    const ubext::RequestFile rf = ubext::ReadRequests(reqPath);
    std::map<long, ubext::Request> byId;
    for (auto const& kv : rf.requests) {
      if (!byId.emplace(kv.second.reqId, kv.second).second) {
        throw cet::exception(kProg) << reqPath << ": req_id " << kv.second.reqId << " twice\n";
      }
    }

    std::map<long, ubext::ServedEvent> served;
    std::map<long, std::pair<Stat, GroupStats const*>> stats;
    std::vector<GroupStats> groupStats;
    groupStats.reserve(groups.size());
    for (auto const& dir : groups) {
      groupStats.push_back(ReadStats(dir + "/uboone_request_stats.dat"));
      GroupStats const& g = groupStats.back();
      for (auto const& kv : g.stats) {
        Stat const& st = kv.second;
        if (!byId.count(st.reqId)) {
          throw cet::exception(kProg) << dir << ": request " << st.reqId
                                      << " is not in " << reqPath << "\n";
        }
        if (!stats.emplace(st.reqId, std::make_pair(st, &g)).second) {
          throw cet::exception(kProg) << dir << ": request " << st.reqId
                                      << " also in another group\n";
        }
        if (st.run <= 0) {
          throw cet::exception(kProg) << dir << ": request " << st.reqId << " was not served\n";
        }
      }

      const std::string hepmc = dir + "/EventOutput.Pert.hepmc3";
      for (auto const& ev : ReadNuHepMC(hepmc)) {
        const std::string where = Where(hepmc, ev.line);
        if (ev.reqId < 0) throw cet::exception(kProg) << where << ": event without request id\n";
        auto st = g.stats.find(ev.reqId);
        if (st == g.stats.end()) {
          throw cet::exception(kProg) << where << ": request " << ev.reqId
                                      << " is not in this group's statistics\n";
        }
        if (served.count(ev.reqId)) {
          throw cet::exception(kProg) << where << ": request " << ev.reqId << " served twice\n";
        }
        served.emplace(ev.reqId, MakeServed(ev, byId.at(ev.reqId), st->second, g, where));
      }
      for (auto const& kv : g.stats) {
        if (!served.count(kv.first)) {
          throw cet::exception(kProg) << dir << ": request " << kv.first
                                      << " served according to the statistics, but has no event"
                                      << " (all its particles lost?)\n";
        }
      }
    }

    if (!allowMissing && served.size() != byId.size()) {
      for (auto const& kv : byId) {
        if (!served.count(kv.first)) {
          throw cet::exception(kProg) << "request " << kv.first << " (and maybe others) of "
                                      << reqPath << " was not served (" << served.size() << " of "
                                      << byId.size() << ")\n";
        }
      }
    }

    FILE* out = std::fopen(outPath.c_str(), "w");
    if (!out) throw cet::exception(kProg) << "cannot write " << outPath << "\n";
    std::fprintf(out, "# extgen-served v1 generator=GiBUU converter=%s requests=%s groups=%zu\n",
                 kProg, reqPath.c_str(), groups.size());
    std::fprintf(out, "# EVENT req_id E_GeV gen_proc simb_mode simb_inttype nparts\n");
    std::fprintf(out, "# P status pdg px py pz E   (GeV, neutrino along +z)\n");
    std::fprintf(out, "# gen_proc = GiBUU.ChannelID\n");
    for (auto const& kv : served) ubext::WriteServedEvent(out, kv.second);
    if (std::fflush(out) != 0 || std::ferror(out) || std::fclose(out) != 0) {
      throw cet::exception(kProg) << "error writing " << outPath << "\n";
    }

    FILE* ts = std::fopen(statPath.c_str(), "w");
    if (!ts) throw cet::exception(kProg) << "cannot write " << statPath << "\n";
    std::fprintf(ts, "# extgen-trial-stats v1 generator=GiBUU\n");
    std::fprintf(ts, "# req_id tgt_pdg nu_pdg ccnc E_GeV n_trials sum_w sum_w2 max_w n_dropped"
                     "   (w: 1e-38 cm^2 per nucleus)\n");
    for (auto const& kv : stats) {
      Stat const& st = kv.second.first;
      const double A = kv.second.second->A;
      ubext::Request const& req = byId.at(st.reqId);
      std::fprintf(ts, "%ld %d %d %s %.17g %lld %.17g %.17g %.17g %ld\n", st.reqId, req.tgtPdg,
                   req.nuPdg, req.isCC ? "CC" : "NC", req.E, st.nTrials, st.sumW * A,
                   st.sumW2 * A * A, st.maxW * A, st.nDropped);
    }
    if (std::fflush(ts) != 0 || std::ferror(ts) || std::fclose(ts) != 0) {
      throw cet::exception(kProg) << "error writing " << statPath << "\n";
    }

    std::cout << kProg << ": " << served.size() << " events from " << groups.size()
              << " GiBUU runs written to " << outPath << "\n";
  }
  catch (cet::exception const& e) {
    std::cerr << kProg << ": ERROR\n" << e.what();
    return 1;
  }
  catch (std::exception const& e) {
    std::cerr << kProg << ": ERROR: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
