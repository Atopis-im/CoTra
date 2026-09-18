# CentOS/AlmaLinux/Rocky (rpm/yum/dnf 系):
rpm -qf /usr/include/numa.h \
       /usr/include/libmemcached/memcached.h \
       /usr/include/boost/program_options.hpp \
       /usr/include/cblas.h \
       /usr/include/lapacke.h \
       /usr/include/libaio.h

# Ubuntu/Debian (dpkg/apt 系):
dpkg -S /usr/include/numa.h \
       /usr/include/libmemcached/memcached.h \
       /usr/include/boost/program_options.hpp \
       /usr/include/cblas.h \
       /usr/include/lapacke.h \
       /usr/include/libaio.h