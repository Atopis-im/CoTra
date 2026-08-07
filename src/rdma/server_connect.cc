#include "rdma/server_connect.h"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <random>

const char *ServerConnect::server_prefix = "SPre";

void ServerConnect::show_states() {
  std::cout << "Connect ";
  for (bool state : states) {
    std::cout << (state ? "√ " : "× ");
  }
  std::cout << std::flush;
}

void ServerConnect::init() {
  std::cout << "Machine ";
  for (size_t i = 0; i < MACHINE_NUM; ++i) {
    std::cout << i << " ";
  }
  std::cout << std::endl;
  memset(states, 0, sizeof(states));
  show_states();
}

bool ServerConnect::exchange_meta(uint16_t remote_id) {
  // get the machine id
  std::string key = get_machine_key(remote_id);
  size_t machine_id_size = 0;
  char *machine_id_data = mc_get(key.c_str(), key.size(), &machine_id_size);
  if (machine_id_size != sizeof(machine_id)) {
    fprintf(stderr, "Invalid machine ID metadata size: %zu\n", machine_id_size);
    free(machine_id_data);
    return false;
  }
  uint16_t m = 0;
  memcpy(&m, machine_id_data, sizeof(m));
  free(machine_id_data);
  if (m >= max_machine) {
    fprintf(stderr, "Invalid remote machine ID: %u\n", m);
    return false;
  }
  setDataToRemote(m);

  std::string setK = set_key(remote_id);
  mc_set(
      setK.c_str(), setK.size(), (char *)(&local_meta[m]),
      sizeof(local_meta[m]));

  std::string getK = get_key(remote_id);
  size_t remote_meta_size = 0;
  ExchangeMeta *remoteMeta =
      (ExchangeMeta *)mc_get(getK.c_str(), getK.size(), &remote_meta_size);
  if (remote_meta_size != sizeof(ExchangeMeta)) {
    fprintf(stderr, "Invalid RDMA metadata size: %zu\n", remote_meta_size);
    free(remoteMeta);
    return false;
  }

  setDataFromRemote(remote_id, remoteMeta);

  free(remoteMeta);
  return true;
}

void ServerConnect::setDataToRemote(uint16_t m) {
  memset(&local_meta[m], 0, sizeof(local_meta[m]));
  local_meta[m].machine_id = machine_id;
  for (int t = 0; t < getActiveThreads(); t++) {
    auto *ctx = rdma_ctx.getRemote(t);
    local_meta[m].thd_msg[t] = ctx->local_mr_msg[m];
  }
}

void ServerConnect::setDataFromRemote(
    uint16_t remote_id, ExchangeMeta *remoteMeta) {
  // printf("recv remote msg: %s\n", remoteMeta->msg);
  uint32_t m = remoteMeta->machine_id;
  if (m >= max_machine) {
    throw std::runtime_error(
        "Remote metadata contains invalid machine ID " + std::to_string(m));
  }
  for (int t = 0; t < getActiveThreads(); t++) {
    auto *ctx = rdma_ctx.getRemote(t);
    ctx->remote_mr_msg[m] = remoteMeta->thd_msg[t];
  }
  states[m] = true;
  std::cout << "\r";
  show_states();
}

void ServerConnect::init_route() {
  std::cout << "\n";
  std::string k =
      std::string(server_prefix) + std::to_string(this->get_my_id());
  mc_set(k.c_str(), k.size(), get_my_ip().c_str(), get_my_ip().size());
}

void ServerConnect::barrier(const std::string &barrierKey) {
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);
  std::string key = std::string("barrier-") + barrierKey;
  memcached_return rc =
      memcached_add(memc, key.c_str(), key.size(), "0", 1, 0, 0);
  if (rc != MEMCACHED_SUCCESS && rc != MEMCACHED_NOTSTORED &&
      rc != MEMCACHED_DATA_EXISTS) {
    throw std::runtime_error(
        "Unable to initialize memcached barrier: " +
        std::string(memcached_strerror(memc, rc)));
  }
  mc_fetch_add(key.c_str(), key.size());
  while (true) {
    char *value = mc_get(key.c_str(), key.size());
    uint64_t v = std::stoull(value);
    free(value);
    if (v == this->get_machine_num()) {
      return;
    }
    if (v > this->get_machine_num()) {
      throw std::runtime_error(
          "Memcached barrier counter is stale; restart the metadata service");
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error(
          "Timed out waiting for memcached barrier " + barrierKey);
    }
    usleep(1000);
  }
}

std::string trim(const std::string &s) {
  const auto first = s.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return "";
  const auto last = s.find_last_not_of(" \t\r\n");
  return s.substr(first, last - first + 1);
}

const char *ServerConnect::machine_num_key = "serverNum";

ServerConnect::~ServerConnect() { disconnect_mc(); }

bool ServerConnect::connect_mc(std::string config_file) {
  memcached_server_st *servers = NULL;
  memcached_return rc;

  // std::ifstream conf("../scripts/memcached.conf");
  std::ifstream conf(config_file);

  if (!conf) {
    fprintf(stderr, "can't open memcached.conf\n");
    return false;
  }

  std::string addr, port;
  std::getline(conf, addr);
  std::getline(conf, port);

  int server_port = 0;
  try {
    server_port = std::stoi(trim(port));
  } catch (const std::exception &) {
    fprintf(stderr, "Invalid memcached port in %s\n", config_file.c_str());
    return false;
  }
  if (server_port < 1 || server_port > 65535) {
    fprintf(
        stderr, "Memcached port is outside the valid range: %d\n",
        server_port);
    return false;
  }

  memc = memcached_create(NULL);
  if (memc == NULL) {
    fprintf(stderr, "Couldn't allocate a memcached client\n");
    return false;
  }

  servers = memcached_server_list_append(
      servers, trim(addr).c_str(), server_port, &rc);
  if (servers == NULL || rc != MEMCACHED_SUCCESS) {
    fprintf(
        stderr, "Couldn't configure the memcached server: %s\n",
        memcached_strerror(memc, rc));
    disconnect_mc();
    return false;
  }

  rc = memcached_server_push(memc, servers);
  memcached_server_list_free(servers);

  if (rc != MEMCACHED_SUCCESS) {
    fprintf(stderr, "Couldn't add server: %s\n", memcached_strerror(memc, rc));
    disconnect_mc();
    return false;
  }

  memcached_behavior_set(memc, MEMCACHED_BEHAVIOR_BINARY_PROTOCOL, 1);
  return true;
}

bool ServerConnect::disconnect_mc() {
  if (memc) {
    memcached_quit(memc);
    memcached_free(memc);
    memc = NULL;
  }
  return true;
}

void ServerConnect::add_machine() {
  memcached_return rc;
  uint64_t serverNum;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);

  while (true) {
    rc = memcached_increment(
        memc, machine_num_key, strlen(machine_num_key), 1, &serverNum);
    if (rc == MEMCACHED_SUCCESS) {
      my_id = serverNum - 1;
      if (serverNum > max_machine) {
        throw std::runtime_error(
            "memcached serverNum exceeds the compiled machine count; clear stale metadata");
      }

      std::string id_k = set_machine_key();
      mc_set(
          id_k.c_str(), id_k.size(), (char *)(&machine_id), sizeof(machine_id));
      // printf("I am server %d real machine id: %u\n", my_id, machine_id);
      return;
    }
    fprintf(
        stderr, "Server %d Counld't incr value and get ID: %s, retry...\n",
        my_id, memcached_strerror(memc, rc));
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error("Timed out registering this node in memcached");
    }
    usleep(10000);
  }
}

void ServerConnect::connect_machine() {
  size_t l;
  uint32_t flags;
  memcached_return rc;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);

  while (cur_machine_num < max_machine) {
    char *serverNumStr = memcached_get(
        memc, machine_num_key, strlen(machine_num_key), &l, &flags, &rc);
    if (rc != MEMCACHED_SUCCESS) {
      fprintf(
          stderr, "Server %d Counld't get serverNum: %s, retry\n", my_id,
          memcached_strerror(memc, rc));
      if (std::chrono::steady_clock::now() >= deadline) {
        throw std::runtime_error("Timed out waiting for all nodes in memcached");
      }
      usleep(10000);
      continue;
    }
    uint32_t serverNum = atoi(serverNumStr);
    free(serverNumStr);
    if (serverNum > max_machine) {
      throw std::runtime_error(
          "memcached serverNum exceeds the compiled machine count; clear stale metadata");
    }

    // /connect server K
    for (size_t k = cur_machine_num; k < serverNum; ++k) {
      if (k != my_id) {
        if (!exchange_meta(k)) {
          throw std::runtime_error("Invalid RDMA metadata from node " + std::to_string(k));
        }
        // printf("I connect server %zu\n", k);
      }
    }
    cur_machine_num = serverNum;
    if (std::chrono::steady_clock::now() >= deadline &&
        cur_machine_num < max_machine) {
      throw std::runtime_error("Timed out waiting for all RDMA metadata");
    }
  }
}

void ServerConnect::mc_set(
    const char *key, uint32_t klen, const char *val, uint32_t vlen) {
  memcached_return rc;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);
  while (true) {
    rc = memcached_set(memc, key, klen, val, vlen, (time_t)0, (uint32_t)0);
    if (rc == MEMCACHED_SUCCESS) {
      break;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error("Timed out writing metadata to memcached");
    }
    usleep(400);
  }
}

char *ServerConnect::mc_get(const char *key, uint32_t klen, size_t *v_size) {
  size_t l;
  char *res;
  uint32_t flags;
  memcached_return rc;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);

  while (true) {
    res = memcached_get(memc, key, klen, &l, &flags, &rc);
    if (rc == MEMCACHED_SUCCESS) {
      break;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error(
          "Timed out reading metadata key " + std::string(key, klen));
    }
    usleep(std::max<uint32_t>(400, 400 * my_id));
  }

  if (v_size != nullptr) {
    *v_size = l;
  }

  return res;
}

uint64_t ServerConnect::mc_fetch_add(const char *key, uint32_t klen) {
  uint64_t res;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(timeout_seconds);
  while (true) {
    memcached_return rc = memcached_increment(memc, key, klen, 1, &res);
    if (rc == MEMCACHED_SUCCESS) {
      return res;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error("Timed out updating a memcached counter");
    }
    usleep(10000);
  }
}
