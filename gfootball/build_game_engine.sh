#!/bin/bash
# Copyright 2019 Google LLC
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

LIB_EXTENSION="so"

if [[ "$OSTYPE" == "darwin"* ]] ; then
    LIB_EXTENSION="dylib"
fi

# Take into account # of cores and available RAM for deciding on compilation parallelism.
# TODO: Try importing psutil and if failed fall back to 1 thread
PARALLELISM=$(python3 -c 'import psutil; import multiprocessing as mp; print(int(max(1,min((psutil.virtual_memory().available/1000000000-1)/0.5, mp.cpu_count()))))')

# Delete pre-existing version of CMakeCache.txt to make 'python3 -m pip install' work.
rm -f third_party/gfootball_engine/CMakeCache.txt
PYTHON_EXE="${GFOOTBALL_PYTHON:-/Users/troyedwards/dev/agentloop/packages/grf-trainer/.conda/bin/python}"
PYTHON_PREFIX="$("$PYTHON_EXE" -c 'import sys; print(sys.prefix)')"
echo "[patched build] Using PYTHON_EXE=$PYTHON_EXE PYTHON_PREFIX=$PYTHON_PREFIX"
pushd third_party/gfootball_engine && cmake . \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_FIND_FRAMEWORK=LAST \
    -DPython_FIND_FRAMEWORK=NEVER \
    -DPython3_FIND_FRAMEWORK=NEVER \
    -DBoost_NO_BOOST_CMAKE=ON \
    -DBoost_USE_STATIC_LIBS=OFF \
    -DBOOST_ROOT="$PYTHON_PREFIX" \
    -DPython_EXECUTABLE="$PYTHON_EXE" \
    -DPython3_EXECUTABLE="$PYTHON_EXE" \
    -DPython_ROOT_DIR="$PYTHON_PREFIX" \
    -DPython3_ROOT_DIR="$PYTHON_PREFIX" \
    -DCMAKE_PREFIX_PATH="/opt/homebrew;$PYTHON_PREFIX" \
    -DSDL2_DIR=/opt/homebrew/lib/cmake/SDL2 \
    && make -j $PARALLELISM && popd
pushd third_party/gfootball_engine && ln -sf libgame.$LIB_EXTENSION _gameplayfootball.so && popd
