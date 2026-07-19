class OciVolumeHydrate < Formula
  desc "Safely hydrate, verify, cut over, and roll back OCI volumes"
  homepage "https://github.com/raymonepping/docker_hydration"
  url "https://github.com/raymonepping/docker_hydration/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "699daa366c2f23e17844f0dc8c88a2d5bcdf5feb889410cf787efa7a114b0ae1"
  license "MIT"

  depends_on "bash"
  depends_on "python@3.14"

  def install
    libexec.install "VERSION"
    (libexec/"scripts").install "scripts/oci-volume-hydrate.sh" => "oci-volume-hydrate"
    (libexec/"docker/volume-helper").install "docker/volume-helper/Dockerfile"

    bin.write_exec_script libexec/"scripts/oci-volume-hydrate"

    doc.install "README.md", "CHANGELOG.md", "docs/release-checklist.md"
  end

  def caveats
    <<~EOS
      A working Docker or Podman runtime and a compatible Compose provider are
      required for migration commands. They are intentionally not installed as
      formula dependencies, so you can choose the OCI runtime you use.

      Start with:
        oci-volume-hydrate --help

      A first --dry-run will not build a missing helper image. Run the exact
      docker/podman build command it prints once, then repeat the dry run.
    EOS
  end

  test do
    assert_equal "oci-volume-hydrate #{version}", shell_output("#{bin}/oci-volume-hydrate --version").strip
    assert_match "Non-destructive, resumable OCI volume hydration", shell_output("#{bin}/oci-volume-hydrate --help")
    assert_path_exists libexec/"docker/volume-helper/Dockerfile"
  end
end
