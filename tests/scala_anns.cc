#include "anns/exec_query.h"
#include "index/graph_index.h"

#include <csignal>
#include <execinfo.h>
#include <cstdlib>
#include <unistd.h>
#include <dlfcn.h>
#include <cxxabi.h>

static void print_frame(void *addr, int idx) {
  Dl_info info;
  memset(&info, 0, sizeof(info));
  const char *sym_name = "??";
  const char *file_name = "??";
  char *demangled = nullptr;
  if (dladdr(addr, &info)) {
    if (info.dli_sname) {
      int status = 0;
      demangled = abi::__cxa_demangle(info.dli_sname, nullptr, nullptr, &status);
      sym_name = (demangled && status == 0) ? demangled : info.dli_sname;
    }
    if (info.dli_fname) file_name = info.dli_fname;
  }
  long offset = info.dli_saddr ? (char *)addr - (char *)info.dli_saddr : -1;
  fprintf(stderr, "#%d %p  %s+0x%lx  (%s)\n",
          idx, addr, sym_name, offset, file_name);
  if (demangled) free(demangled);
}

static void crash_handler(int sig) {
  fprintf(stderr, "\n===== CRASH (signal %d) =====\n", sig);
  void *bt[64];
  int n = backtrace(bt, 64);
  for (int i = 0; i < n; ++i) print_frame(bt[i], i);
  fprintf(stderr, "===== END BACKTRACE =====\n");
  fprintf(stderr, "Resolve exact line with: addr2line -e build/tests/scala_anns -f -C <addr>\n");
  _exit(sig);
}

// ../scripts/scala_anns.sh
int main(int argc, char **argv) {
  signal(SIGSEGV, crash_handler);
  signal(SIGABRT, crash_handler);
  signal(SIGFPE, crash_handler);
  signal(SIGBUS, crash_handler);
  setbuf(stdout, NULL);
  setbuf(stderr, NULL);
SharedMem coromem;
// coromem.tp.hw_info.show();

commandLine cmd(
argc, argv,
"Usage : -d <data_path> -q <query_path> -m <merge_index> -i <index> -g "
"<gt> --<app_type = single, b1, b2, b1_migrate, b1_migrate_async, "
"b1_async, scala_v0, scala_v1>\n");

// AnnsParameter anns_param(cmd);

RdmaParameter rdma_param(cmd);
IndexParameter index_param(argc, argv);
AnnsParameter anns_param(argc, argv, index_param);

GraphIndex graph_index(index_param);

if(anns_param.dist_fn == std::string("l2")){
if(anns_param.data_type_str == std::string("uint8")){
anns_param.load_query_gt(anns_param.int_answers);
ScalaSearch<int> appr_alg(anns_param, rdma_param, anns_param.l2_space_i, graph_index);
appr_alg.set_evaluation_save_path(anns_param.evaluation_save_path);
test_vs_recall<int>(anns_param, appr_alg, anns_param.int_answers);
}
else if(anns_param.data_type_str == std::string("int8")){
anns_param.load_query_gt(anns_param.int_answers);
ScalaSearch<int> appr_alg(anns_param, rdma_param, anns_param.l2_space_ii, graph_index);
appr_alg.set_evaluation_save_path(anns_param.evaluation_save_path);
test_vs_recall<int>(anns_param, appr_alg, anns_param.int_answers);
}
else if(anns_param.data_type_str == std::string("float")){
anns_param.load_query_gt(anns_param.float_answers);
ScalaSearch<float> appr_alg(anns_param, rdma_param, anns_param.l2_space, graph_index);
appr_alg.set_evaluation_save_path(anns_param.evaluation_save_path);
test_vs_recall<float>(anns_param, appr_alg, anns_param.float_answers);
}
}else if(anns_param.dist_fn == std::string("mips")){
anns_param.load_query_gt(anns_param.float_answers);
ScalaSearch<float> appr_alg(anns_param, rdma_param, anns_param.ip_space, graph_index);
appr_alg.set_evaluation_save_path(anns_param.evaluation_save_path);
test_vs_recall<float>(anns_param, appr_alg, anns_param.float_answers);
} else{
std::cerr<<"Error unexpected dist function.\n";
abort();
}

cout << "Actual memory usage: " << getCurrentRSS() / 1000000 << " Mb \n";

return 0;
}