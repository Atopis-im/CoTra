#include "rdma/ip_config.h"

#include <algorithm>

namespace {
std::string trim_config_value(const std::string &value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return "";
  const auto last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}
}  // namespace

std::vector<std::string> get_local_ip_addrs() {
  std::vector<std::string> addresses;
  struct ifaddrs *ifaddr, *ifa;
  char ip[INET_ADDRSTRLEN];

  if (getifaddrs(&ifaddr) == -1) {
    perror("getifaddrs");
    return addresses;
  }

  for (ifa = ifaddr; ifa != nullptr; ifa = ifa->ifa_next) {
    if (ifa->ifa_addr == nullptr) continue;
    if (ifa->ifa_addr->sa_family == AF_INET) {
      struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
      inet_ntop(AF_INET, &(sa->sin_addr), ip, INET_ADDRSTRLEN);
      std::string ifaceName(ifa->ifa_name);
      std::string address(ip);
      if (ifaceName != "lo" && address.rfind("127.", 0) != 0) {
        addresses.push_back(address);
      }
    }
  }

  freeifaddrs(ifaddr);
  return addresses;
}

// Get the first non-loopback address for compatibility with older callers.
std::string get_local_ip_addr() {
  auto addresses = get_local_ip_addrs();
  return addresses.empty() ? "" : addresses.front();
}

// DNS
std::string resolve_hostname(const std::string &hostname) {
  struct addrinfo hints {}, *res;
  hints.ai_family = AF_INET;  // IPv4 only
  hints.ai_socktype = SOCK_STREAM;

  // 解析主机名
  const std::string clean_hostname = trim_config_value(hostname);
  if (getaddrinfo(clean_hostname.c_str(), nullptr, &hints, &res) != 0) {
    std::cerr << "getaddrinfo failed for hostname: " << hostname << std::endl;
    return "";
  }

  std::string result;
  for (struct addrinfo *p = res; p != nullptr; p = p->ai_next) {
    char ip[INET_ADDRSTRLEN];
    auto *addr = (struct sockaddr_in *)p->ai_addr;
    inet_ntop(AF_INET, &(addr->sin_addr), ip, INET_ADDRSTRLEN);

    // pass 127.0.0.1
    if (std::string(ip).find("127.") != 0) {
      result = ip;
      break;  
    }
  }

  freeaddrinfo(res);

  if (result.empty()) {
      std::cerr << "No non-loopback address found for hostname: " << hostname << std::endl;
  }

  return result;
}


// read ip_list
std::unordered_map<std::string, int> read_ip_map(const std::string &filename) {
  std::unordered_map<std::string, int> ipMap;
  std::ifstream file(filename);

  if (!file.is_open()) {
    std::cerr << "Fatal error: Can not open ip_list file: " << filename
              << std::endl;
    return ipMap;
  }

  // get first line of leader machine info. 
  std::string addr, port;
  std::getline(file, addr);
  std::getline(file, port);

  std::string line;
  while (std::getline(file, line)) {
    std::istringstream iss(line);
    std::string hostOrIP;
    int id;
    if (std::getline(iss, hostOrIP, '=') && iss >> id) {
      hostOrIP = trim_config_value(hostOrIP);
      std::string ip = resolve_hostname(hostOrIP);
      if (!ip.empty()) {
        ipMap[ip] = id;
      } else {
        std::cerr << "WARN: Can not resolve" << hostOrIP << ", skip."
                  << std::endl;
      }
    }
  }

  file.close();
  return ipMap;
}

int get_machine_id(std::string config_file) {
  // const std::string configFile = "../scripts/ip_list.conf";

  auto ipMap = read_ip_map(config_file);

  if (ipMap.empty()) {
    std::cerr << "Error: ip_list file is empty or cannot resolve " << std::endl;
    return -1;
  }

  auto local_addresses = get_local_ip_addrs();
  if (local_addresses.empty()) {
    std::cerr << "Can not get local IP addr." << std::endl;
    return -1;
  }

  int machine_id = -1;
  for (const auto &local_ip : local_addresses) {
    std::cout << "Local IPv4 address: " << local_ip << std::endl;
    auto it = ipMap.find(local_ip);
    if (it != ipMap.end()) {
      machine_id = it->second;
      std::cout << "Matched machine ID " << machine_id << " using " << local_ip
                << std::endl;
      break;
    }
  }
  if (machine_id < 0) {
    std::cerr << "Error: none of the local IPv4 addresses appears in "
              << config_file << std::endl;
  }

  return machine_id;
}


std::vector<std::string> get_machine_name(std::string config_file){
  std::vector<std::pair<int, std::string>> entries;
  std::ifstream file(config_file);

  if (!file.is_open()) {
    std::cerr << "Fatal error: Can not open ip_list file: " << config_file
              << std::endl;
    return {};
  }

  // get first line of leader machine info. 
  std::string addr, port;
  std::getline(file, addr);
  std::getline(file, port);

  std::string line;
  while (std::getline(file, line)) {
    std::istringstream iss(line);
    std::string hostOrIP;
    int id;
    if (std::getline(iss, hostOrIP, '=') && iss >> id) {
      entries.emplace_back(id, trim_config_value(hostOrIP));
    }
  }

  file.close();
  for (const auto &entry : entries) {
    if (entry.first < 0 || static_cast<size_t>(entry.first) >= entries.size()) {
      std::cerr << "Machine IDs must be contiguous from zero in " << config_file
                << std::endl;
      return {};
    }
  }
  int max_id = -1;
  for (const auto &entry : entries) max_id = std::max(max_id, entry.first);
  std::vector<std::string> machine_name(max_id + 1);
  for (const auto &entry : entries) {
    if (entry.first < 0 || !machine_name[entry.first].empty()) {
      std::cerr << "Invalid or duplicate machine ID " << entry.first << " in "
                << config_file << std::endl;
      return {};
    }
    machine_name[entry.first] = entry.second;
  }
  for (size_t id = 0; id < machine_name.size(); ++id) {
    if (machine_name[id].empty()) {
      std::cerr << "Missing machine ID " << id << " in " << config_file
                << std::endl;
      return {};
    }
  }
  return machine_name;
}
