class Herd < Formula
  desc "Manage multiple Git and Jujutsu repositories"
  homepage "https://github.com/schmir/herd"
  url "https://github.com/schmir/herd/archive/refs/tags/v0.0.1.tar.gz"
  sha256 "3b2c6ecc278c2f35df3596b20615c5298d9dc646758cfb8eed83634ad9645e4d"
  license "GPL-3.0-only"

  depends_on "janet" => :build
  depends_on "jj"

  resource "spork" do
    url "https://github.com/janet-lang/spork/archive/refs/tags/v1.2.0.tar.gz"
    sha256 "eab22f09a5512b098587c08adf7917c48eeb999763aaa562a035e00e006181dd"
  end

  def install
    resource("spork").stage do
      system "jpm", "--tree=#{buildpath/"jpm_tree"}", "install"
    end
    system "jpm", "--local", "build"
    bin.install "build/herd"
  end

  test do
    config = testpath/"repositories.json"
    config.write "[]"
    assert_equal "0 cloned, 0 already checked out, 0 failed\n",
                 shell_output("#{bin}/herd #{config}")
  end
end
