FROM gcr.io/oss-fuzz-base/base-builder
RUN git clone --depth 1 --branch v1.5.6 https://github.com/facebook/zstd.git $SRC/zstd
COPY . $SRC/aceapex
WORKDIR $SRC/aceapex
COPY .clusterfuzzlite/build.sh $SRC/
