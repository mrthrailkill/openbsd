sh_binary(
  name = "create_gce_image",
  srcs = [
    "create_gce_image.openbsd.bash",
  ],
  data = [
    ":defaults",
  ],
  deps = [
    "@bazel_tools//tools/bash/runfiles",
    "@shflags//:libshflags",
  ],
)

filegroup(
  name = "defaults",
  srcs = glob([
    "default/*",
  ]),
)
