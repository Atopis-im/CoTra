#!/usr/bin/env python3
"""
apply_8p4n_cxx_edits.py
=======================

Applies the C++ source edits that turn CoTra into the
"8 processes / 4 nodes" (2 CoTra processes per physical node) variant.

This patcher targets the repo layout that contains the warmup_runs /
warmup_ef / num_runs additions in src/index/index_param.cc (the tree that
also ships build_index_cotra.sh / run_anns_cotra.sh and scripts/arm_roce_8node.sh).

It edits exactly two files:
  - src/rdma/rdma_param.cc      (1 edit)
  - src/index/index_param.cc    (5 edits)

Each edit is a verified literal string replacement:
  * if the NEW text is already present  -> the edit is skipped (already applied)
  * elif the OLD text occurs exactly once -> it is replaced
  * else -> the script aborts with an error and writes NOTHING back, so a
    partial/failed run never leaves the sources half-edited.

Usage:
  python3 scripts/apply_8p4n_cxx_edits.py [REPO_ROOT]

  REPO_ROOT defaults to the current working directory. Run it from the repo
  root, or pass the repo root explicitly, e.g.:
      python3 scripts/apply_8p4n_cxx_edits.py /home/team/alg_mathlib/c30061081/CoTra

What the edits do (summary):
  * rdma_param.cc : add an explicit --rank option. When --rank >= 0 is given,
    machine_id is taken directly from it and the IP->id lookup
    (get_machine_id) is skipped -- that lookup cannot tell two processes on
    the same node apart. The range check is strengthened to [0, MACHINE_NUM).
  * index_param.cc AnnsParameter: register --rank and set machine_id from it
    (the legacy constructor left machine_id UNSET -- a latent bug fixed here).
  * index_param.cc IndexParameter: register --rank, capture it, and use it for
    machine_id with a range check.

After patching, build with -DCOTRA_MACHINE_NUM=8 (NOT 4): MACHINE_NUM is the
number of CoTra processes/ranks, not physical nodes. The launcher
scripts/arm_roce_4node_8proc.sh passes this automatically.
"""

import os
import sys

# ---------------------------------------------------------------------------
# Edit table: (relative_path, old_text, new_text, label)
# Whitespace/indentation in these strings MUST match the source exactly.
# ---------------------------------------------------------------------------
EDITS = []

def add(rel, old, new, label):
    EDITS.append((rel, old, new, label))


# --- src/rdma/rdma_param.cc : 1 edit ---------------------------------------
add(
    "src/rdma/rdma_param.cc",
    """  machine_num = MACHINE_NUM;
  // machine_id = cmd.getOptionIntValue("-m", 0);
  machine_id = get_machine_id(ip_config_file);
  machine_name = get_machine_name(ip_config_file);
  if (machine_id < 0 || machine_name.size() != MACHINE_NUM) {""",
    """  machine_num = MACHINE_NUM;
  // machine_id: explicit --rank enables multi-process-per-node (several CoTra
  // processes on one host sharing one RoCE NIC). When --rank is given, use it
  // directly as the per-process machine_id and skip the IP->ID lookup, which
  // cannot distinguish two processes that share the same local IP. When --rank
  // is absent, fall back to the legacy IP-based lookup (one process per node).
  {
    char *rank_str = cmd.getOptionValue("--rank");
    int rank = (rank_str != nullptr) ? atoi(rank_str) : -1;
    if (rank >= 0) {
      machine_id = rank;
    } else {
      machine_id = get_machine_id(ip_config_file);
    }
  }
  machine_name = get_machine_name(ip_config_file);
  if (machine_id < 0 || machine_id >= MACHINE_NUM ||
      machine_name.size() != MACHINE_NUM) {""",
    "rdma_param.cc: --rank -> machine_id (skip IP lookup, range check)",
)

# --- src/index/index_param.cc : AnnsParameter, add --rank option -----------
add(
    "src/index/index_param.cc",
    """        "scala_v3", po::bool_switch()->default_value(false), "Search version");
    // Merge required and optional parameters
    desc.add(required_configs).add(optional_configs);""",
    """        "scala_v3", po::bool_switch()->default_value(false), "Search version");
    optional_configs.add_options()(
        "rank", po::value<int>()->default_value(-1),
        "Explicit per-process rank in [0,MACHINE_NUM); required for "
        "multi-process-per-node, overrides IP-based machine_id lookup.");
    // Merge required and optional parameters
    desc.add(required_configs).add(optional_configs);""",
    "index_param.cc AnnsParameter: register --rank option",
)

# --- src/index/index_param.cc : AnnsParameter, set machine_id from --rank --
add(
    "src/index/index_param.cc",
    """  machine_id = get_machine_id(config_file);
  vecsize = index_param.vec_size;""",
    """  // machine_id: explicit --rank for multi-process-per-node, else IP-based
  // lookup. The legacy constructor left this member unset; set it explicitly
  // here so the search layer's self/leader comparisons use the real rank.
  {
    int rank = vm["rank"].as<int>();
    if (rank >= 0) {
      machine_id = rank;
    } else {
      machine_id = get_machine_id(config_file);
    }
    if (machine_id < 0 || machine_id >= MACHINE_NUM) {
      std::cerr << "Error: rank/machine_id " << machine_id
                << " is out of range [0," << MACHINE_NUM << ").\\n";
      abort();
    }
  }
  vecsize = index_param.vec_size;""",
    "index_param.cc AnnsParameter: set machine_id from --rank (fixes unset bug)",
)

# --- src/index/index_param.cc : IndexParameter, add rank_override var -------
add(
    "src/index/index_param.cc",
    """  num_parts = MACHINE_NUM;

  std::cout << "Using meta_data_ratio: " << _meta_data_ratio << std::endl;""",
    """  num_parts = MACHINE_NUM;

  int rank_override = -1;  // captured from --rank inside the try below

  std::cout << "Using meta_data_ratio: " << _meta_data_ratio << std::endl;""",
    "index_param.cc IndexParameter: declare rank_override",
)

# --- src/index/index_param.cc : IndexParameter, register --rank option ------
add(
    "src/index/index_param.cc",
    """    optional_configs.add_options()(
      "topindex_deg", po::value<uint32_t>(&topindex_deg)->default_value(16),
      "Top HNSW index degree");""",
    """    optional_configs.add_options()(
      "topindex_deg", po::value<uint32_t>(&topindex_deg)->default_value(16),
      "Top HNSW index degree");
    optional_configs.add_options()(
        "rank", po::value<int>()->default_value(-1),
        "Explicit per-process rank in [0,MACHINE_NUM); required for "
        "multi-process-per-node, overrides IP-based machine_id lookup.");""",
    "index_param.cc IndexParameter: register --rank option",
)

# --- src/index/index_param.cc : IndexParameter, capture rank_override -------
add(
    "src/index/index_param.cc",
    """    if (vm["append_reorder_data"].as<bool>()) append_reorder_data = true;
    if (vm["use_opq"].as<bool>()) use_opq = true;
  } catch (const std::exception &ex) {""",
    """    if (vm["append_reorder_data"].as<bool>()) append_reorder_data = true;
    if (vm["use_opq"].as<bool>()) use_opq = true;
    rank_override = vm["rank"].as<int>();
  } catch (const std::exception &ex) {""",
    "index_param.cc IndexParameter: capture rank_override from vm",
)

# --- src/index/index_param.cc : IndexParameter, set machine_id from --rank --
add(
    "src/index/index_param.cc",
    """  machine_id = get_machine_id(config_file);

  bool use_filters = (label_file != "") ? true : false;""",
    """  // machine_id: explicit --rank for multi-process-per-node, else IP-based lookup.
  if (rank_override >= 0) {
    machine_id = static_cast<uint32_t>(rank_override);
  } else {
    machine_id = static_cast<uint32_t>(get_machine_id(config_file));
  }
  if (machine_id >= static_cast<uint32_t>(MACHINE_NUM)) {
    std::cerr << "Error: rank/machine_id " << machine_id
              << " is out of range [0," << MACHINE_NUM << ").\\n";
    abort();
  }

  bool use_filters = (label_file != "") ? true : false;""",
    "index_param.cc IndexParameter: set machine_id from --rank (range check)",
)


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    repo = os.path.abspath(repo)
    if not os.path.isdir(repo):
        sys.exit("error: repo root not found: %s" % repo)

    # Group edits by file so we read/write each file at most once and abort
    # cleanly (without writing) if ANY edit in a file is ambiguous.
    by_file = {}
    for rel, old, new, label in EDITS:
        by_file.setdefault(rel, []).append((old, new, label))

    plan = {}      # rel -> (original_text, new_text, applied_labels, skipped_labels)
    all_ok = True
    for rel, edits in by_file.items():
        path = os.path.join(repo, rel.replace("/", os.sep))
        if not os.path.isfile(path):
            print("ERROR: file not found: %s" % path)
            all_ok = False
            continue
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        applied = []
        skipped = []
        for old, new, label in edits:
            if new in content:
                skipped.append(label)
                continue
            cnt = content.count(old)
            if cnt == 1:
                content = content.replace(old, new, 1)
                applied.append(label)
            else:
                print("ERROR: edit did not match exactly once (matched %d) in %s:" % (cnt, rel))
                print("        %s" % label)
                all_ok = False
        plan[rel] = (path, content, applied, skipped)

    if not all_ok:
        print("")
        print("Aborting: one or more edits could not be applied uniquely.")
        print("No files were modified. Check that this patcher is run on the")
        print("correct tree (the one with warmup_runs/num_runs in index_param.cc)")
        print("and that the sources have not already been partially edited.")
        sys.exit(1)

    any_written = False
    for rel, (path, content, applied, skipped) in plan.items():
        for label in skipped:
            print("  skip (already applied): %s  [%s]" % (rel, label))
        for label in applied:
            print("  apply: %s  [%s]" % (rel, label))
        if applied:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            any_written = True

    print("")
    if any_written:
        print("Done. C++ sources patched for 8-process/4-node mode.")
        print("Next: rebuild with -DCOTRA_MACHINE_NUM=8 (use scripts/arm_roce_4node_8proc.sh build).")
    else:
        print("Done. All edits were already present -- nothing to write.")
    print("Remember: MACHINE_NUM=8 (process count), NOT 4 (node count).")


if __name__ == "__main__":
    main()
