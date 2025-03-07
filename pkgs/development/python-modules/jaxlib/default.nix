{ lib
, pkgs
, stdenv

  # Build-time dependencies:
, addOpenGLRunpath
, bazel_5
, binutils
, buildBazelPackage
, buildPythonPackage
, cctools
, curl
, cython
, fetchFromGitHub
, git
, IOKit
, jsoncpp
, nsync
, openssl
, pybind11
, setuptools
, symlinkJoin
, wheel
, which

  # Python dependencies:
, absl-py
, flatbuffers
, numpy
, scipy
, six

  # Runtime dependencies:
, double-conversion
, giflib
, grpc
, libjpeg_turbo
, protobuf
, python
, snappy
, zlib

, config
  # CUDA flags:
, cudaSupport ? config.cudaSupport
, cudaPackages ? {}

  # MKL:
, mklSupport ? true
}:

let
  inherit (cudaPackages) backendStdenv cudatoolkit cudaFlags cudnn nccl;

  pname = "jaxlib";
  version = "0.4.4";

  meta = with lib; {
    description = "JAX is Autograd and XLA, brought together for high-performance machine learning research.";
    homepage = "https://github.com/google/jax";
    license = licenses.asl20;
    maintainers = with maintainers; [ ndl ];
    platforms = platforms.unix;
    # aarch64-darwin is broken because of https://github.com/bazelbuild/rules_cc/pull/136
    # however even with that fix applied, it doesn't work for everyone:
    # https://github.com/NixOS/nixpkgs/pull/184395#issuecomment-1207287129
    broken = stdenv.isDarwin;
  };

  cudatoolkit_joined = symlinkJoin {
    name = "${cudatoolkit.name}-merged";
    paths = [
      cudatoolkit.lib
      cudatoolkit.out
    ] ++ lib.optionals (lib.versionOlder cudatoolkit.version "11") [
      # for some reason some of the required libs are in the targets/x86_64-linux
      # directory; not sure why but this works around it
      "${cudatoolkit}/targets/${stdenv.system}"
    ];
  };

  cudatoolkit_cc_joined = symlinkJoin {
    name = "${cudatoolkit.cc.name}-merged";
    paths = [
      backendStdenv.cc
      binutils.bintools # for ar, dwp, nm, objcopy, objdump, strip
    ];
  };

  # Copy-paste from TF derivation.
  # Most of these are not really used in jaxlib compilation but it's simpler to keep it
  # 'as is' so that it's more compatible with TF derivation.
  tf_system_libs = [
    "absl_py"
    "astor_archive"
    "astunparse_archive"
    "boringssl"
    # Not packaged in nixpkgs
    # "com_github_googleapis_googleapis"
    # "com_github_googlecloudplatform_google_cloud_cpp"
    "com_github_grpc_grpc"
    "com_google_protobuf"
    # Fails with the error: external/org_tensorflow/tensorflow/core/profiler/utils/tf_op_utils.cc:46:49: error: no matching function for call to 're2::RE2::FullMatch(absl::lts_2020_02_25::string_view&, re2::RE2&)'
    # "com_googlesource_code_re2"
    "curl"
    "cython"
    "dill_archive"
    "double_conversion"
    "flatbuffers"
    "functools32_archive"
    "gast_archive"
    "gif"
    "hwloc"
    "icu"
    "jsoncpp_git"
    "libjpeg_turbo"
    "lmdb"
    "nasm"
    "opt_einsum_archive"
    "org_sqlite"
    "pasta"
    "png"
    "pybind11"
    "six_archive"
    "snappy"
    "tblib_archive"
    "termcolor_archive"
    "typing_extensions_archive"
    "wrapt"
    "zlib"
  ];

  arch =
    # KeyError: ('Linux', 'arm64')
    if stdenv.targetPlatform.isLinux && stdenv.targetPlatform.linuxArch == "arm64" then "aarch64"
    else stdenv.targetPlatform.linuxArch;

  bazel-build = buildBazelPackage rec {
    name = "bazel-build-${pname}-${version}";

    bazel = bazel_5;

    src = fetchFromGitHub {
      owner = "google";
      repo = "jax";
      # google/jax contains tags for jax and jaxlib. Only use jaxlib tags!
      rev = "refs/tags/${pname}-v${version}";
      hash = "sha256-DP68UwS9bg243iWU4MLHN0pwl8LaOcW3Sle1ZjsLOHo=";
    };

    nativeBuildInputs = [
      cython
      pkgs.flatbuffers
      git
      setuptools
      wheel
      which
    ] ++ lib.optionals stdenv.isDarwin [
      cctools
    ];

    buildInputs = [
      curl
      double-conversion
      giflib
      grpc
      jsoncpp
      libjpeg_turbo
      numpy
      openssl
      pkgs.flatbuffers
      protobuf
      pybind11
      scipy
      six
      snappy
      zlib
    ] ++ lib.optionals cudaSupport [
      cudatoolkit
      cudnn
    ] ++ lib.optionals stdenv.isDarwin [
      IOKit
    ] ++ lib.optionals (!stdenv.isDarwin) [
      nsync
    ];

    postPatch = ''
      rm -f .bazelversion
    '';

    bazelTargets = [ "//build:build_wheel" ];

    removeRulesCC = false;

    GCC_HOST_COMPILER_PREFIX = lib.optionalString cudaSupport "${cudatoolkit_cc_joined}/bin";
    GCC_HOST_COMPILER_PATH = lib.optionalString cudaSupport "${cudatoolkit_cc_joined}/bin/gcc";

    preConfigure = ''
      # dummy ldconfig
      mkdir dummy-ldconfig
      echo "#!${stdenv.shell}" > dummy-ldconfig/ldconfig
      chmod +x dummy-ldconfig/ldconfig
      export PATH="$PWD/dummy-ldconfig:$PATH"
      cat <<CFG > ./.jax_configure.bazelrc
      build --strategy=Genrule=standalone
      build --repo_env PYTHON_BIN_PATH="${python}/bin/python"
      build --action_env=PYENV_ROOT
      build --python_path="${python}/bin/python"
      build --distinct_host_configuration=false
      build --define PROTOBUF_INCLUDE_PATH="${protobuf}/include"
    '' + lib.optionalString cudaSupport ''
      build --action_env CUDA_TOOLKIT_PATH="${cudatoolkit_joined}"
      build --action_env CUDNN_INSTALL_PATH="${cudnn}"
      build --action_env TF_CUDA_PATHS="${cudatoolkit_joined},${cudnn},${nccl}"
      build --action_env TF_CUDA_VERSION="${lib.versions.majorMinor cudatoolkit.version}"
      build --action_env TF_CUDNN_VERSION="${lib.versions.major cudnn.version}"
      build:cuda --action_env TF_CUDA_COMPUTE_CAPABILITIES="${builtins.concatStringsSep "," cudaFlags.realArches}"
    '' + ''
      CFG
    '';

    # Make sure Bazel knows about our configuration flags during fetching so that the
    # relevant dependencies can be downloaded.
    bazelFlags = [
      "-c opt"
    ] ++ lib.optionals stdenv.cc.isClang [
      # bazel depends on the compiler frontend automatically selecting these flags based on file
      # extension but our clang doesn't.
      # https://github.com/NixOS/nixpkgs/issues/150655
      "--cxxopt=-x" "--cxxopt=c++" "--host_cxxopt=-x" "--host_cxxopt=c++"
    ];

    # We intentionally overfetch so we can share the fetch derivation across all the different configurations
    fetchAttrs = {
      TF_SYSTEM_LIBS = lib.concatStringsSep "," tf_system_libs;
      # we have to force @mkl_dnn_v1 since it's not needed on darwin
      bazelTargets = bazelTargets ++ [ "@mkl_dnn_v1//:mkl_dnn" ];
      bazelFlags = bazelFlags ++ [
        "--config=avx_posix"
      ] ++ lib.optionals cudaSupport [
        # ideally we'd add this unconditionally too, but it doesn't work on darwin
        # we make this conditional on `cudaSupport` instead of the system, so that the hash for both
        # the cuda and the non-cuda deps can be computed on linux, since a lot of contributors don't
        # have access to darwin machines
        "--config=cuda"
      ] ++ [
        "--config=mkl_open_source_only"
      ];

      sha256 =
        if cudaSupport then
          "sha256-O6bM7Lc8eaFyO4Xzl5/hvBrbPioI+Yeqx9yNC97fvKk="
        else
          "sha256-gLMJfJSQIdGGY2Ivx4IgDWg0hc+mxzlqY11CUkSWcjI=";
    };

    buildAttrs = {
      outputs = [ "out" ];

      TF_SYSTEM_LIBS = lib.concatStringsSep "," (tf_system_libs ++ lib.optionals (!stdenv.isDarwin) [
        "nsync" # fails to build on darwin
      ]);

      bazelFlags = bazelFlags ++ lib.optionals (stdenv.targetPlatform.isx86_64 && stdenv.targetPlatform.isUnix) [
        "--config=avx_posix"
      ] ++ lib.optionals cudaSupport [
        "--config=cuda"
      ] ++ lib.optionals mklSupport [
        "--config=mkl_open_source_only"
      ];
      # Note: we cannot do most of this patching at `patch` phase as the deps are not available yet.
      # 1) Fix pybind11 include paths.
      # 2) Link protobuf from nixpkgs (through TF_SYSTEM_LIBS when using gcc) to prevent crashes on
      #    loading multiple extensions in the same python program due to duplicate protobuf DBs.
      # 3) Patch python path in the compiler driver.
      preBuild = ''
        for src in ./jaxlib/*.{cc,h} ./jaxlib/cuda/*.{cc,h}; do
          sed -i 's@include/pybind11@pybind11@g' $src
        done
      '' + lib.optionalString cudaSupport ''
        export NIX_LDFLAGS+=" -L${backendStdenv.nixpkgsCompatibleLibstdcxx}/lib"
        patchShebangs ../output/external/org_tensorflow/third_party/gpus/crosstool/clang/bin/crosstool_wrapper_driver_is_not_gcc.tpl
      '' + lib.optionalString stdenv.isDarwin ''
        # Framework search paths aren't added by bintools hook
        # https://github.com/NixOS/nixpkgs/pull/41914
        export NIX_LDFLAGS+=" -F${IOKit}/Library/Frameworks"
        substituteInPlace ../output/external/rules_cc/cc/private/toolchain/osx_cc_wrapper.sh.tpl \
          --replace "/usr/bin/install_name_tool" "${cctools}/bin/install_name_tool"
        substituteInPlace ../output/external/rules_cc/cc/private/toolchain/unix_cc_configure.bzl \
          --replace "/usr/bin/libtool" "${cctools}/bin/libtool"
      '' + (if stdenv.cc.isGNU then ''
        sed -i 's@-lprotobuf@-l:libprotobuf.a@' ../output/external/org_tensorflow/third_party/systemlibs/protobuf.BUILD
        sed -i 's@-lprotoc@-l:libprotoc.a@' ../output/external/org_tensorflow/third_party/systemlibs/protobuf.BUILD
      '' else if stdenv.cc.isClang then ''
        sed -i 's@-lprotobuf@${protobuf}/lib/libprotobuf.a@' ../output/external/org_tensorflow/third_party/systemlibs/protobuf.BUILD
        sed -i 's@-lprotoc@${protobuf}/lib/libprotoc.a@' ../output/external/org_tensorflow/third_party/systemlibs/protobuf.BUILD
      '' else throw "Unsupported stdenv.cc: ${stdenv.cc}");

      installPhase = ''
        ./bazel-bin/build/build_wheel --output_path=$out --cpu=${arch}
      '';
    };

    inherit meta;
  };
  platformTag =
    if stdenv.targetPlatform.isLinux then
      "manylinux2014_${arch}"
    else if stdenv.system == "x86_64-darwin" then
      "macosx_10_9_${arch}"
    else if stdenv.system == "aarch64-darwin" then
      "macosx_11_0_${arch}"
    else throw "Unsupported target platform: ${stdenv.targetPlatform}";

in
buildPythonPackage {
  inherit meta pname version;
  format = "wheel";

  src =
    let cp = "cp${builtins.replaceStrings ["."] [""] python.pythonVersion}";
    in "${bazel-build}/jaxlib-${version}-${cp}-${cp}-${platformTag}.whl";

  # Note that cudatoolkit is necessary since jaxlib looks for "ptxas" in $PATH.
  # See https://github.com/NixOS/nixpkgs/pull/164176#discussion_r828801621 for
  # more info.
  postInstall = lib.optionalString cudaSupport ''
    mkdir -p $out/bin
    ln -s ${cudatoolkit}/bin/ptxas $out/bin/ptxas

    find $out -type f \( -name '*.so' -or -name '*.so.*' \) | while read lib; do
      addOpenGLRunpath "$lib"
      patchelf --set-rpath "${cudatoolkit}/lib:${cudatoolkit.lib}/lib:${cudnn}/lib:${nccl}/lib:$(patchelf --print-rpath "$lib")" "$lib"
    done
  '';

  nativeBuildInputs = lib.optional cudaSupport addOpenGLRunpath;

  propagatedBuildInputs = [
    absl-py
    curl
    double-conversion
    flatbuffers
    giflib
    grpc
    jsoncpp
    libjpeg_turbo
    numpy
    scipy
    six
    snappy
  ];

  pythonImportsCheck = [ "jaxlib" ];

  # Without it there are complaints about libcudart.so.11.0 not being found
  # because RPATH path entries added above are stripped.
  dontPatchELF = cudaSupport;
}
