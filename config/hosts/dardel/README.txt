# Dardel HPE Cray EX, Gnu toolchain

# Load environment
ml PDC/21.11
ml cpeGNU/21.11
ml cray-hdf5-parallel/1.12.1.1

# Build with -shlib linking flag HDF5 libraries
FDFLAGS+=-shlib pc_build -f ../../config/hosts/dardel/host-uan01-GNU-CrayWrapp.conf
