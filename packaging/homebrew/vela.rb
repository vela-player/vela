# Homebrew formula for vela. The release workflow copies this into the
# technitish9123/homebrew-tap repository with the version and sha256 filled in.
class Vela < Formula
  desc "Ultra-fast, ultra-light media player for macOS"
  homepage "https://github.com/technitish9123/vela"
  url "https://github.com/technitish9123/vela/archive/refs/tags/v@VERSION@.tar.gz"
  sha256 "@SHA256@"
  license "GPL-3.0-or-later"
  head "https://github.com/technitish9123/vela.git", branch: "main"

  depends_on macos: :ventura
  depends_on "mpv"

  def install
    # Link against mpv's opt path so vela keeps working across mpv upgrades.
    ENV["MPV_PREFIX"] = Formula["mpv"].opt_prefix
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/vela"
  end

  def caveats
    <<~EOS
      Play a file:   vela movie.mkv
      Defaults:      ~/.config/vela/config  (one mpv option per line)
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/vela --version")
  end
end
