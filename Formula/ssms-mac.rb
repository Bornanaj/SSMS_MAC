# Homebrew formula. Building from source is deliberate: a compiled app carries no
# quarantine attribute, so it opens without a Gatekeeper prompt.
#
#   brew tap bornanaj/ssms https://github.com/Bornanaj/SSMS_MAC.git
#   brew install --HEAD bornanaj/ssms/ssms-mac
class SsmsMac < Formula
  desc "Native macOS SQL Server client with Object Explorer, T-SQL editor and results grid"
  homepage "https://github.com/Bornanaj/SSMS_MAC"
  url "https://github.com/Bornanaj/SSMS_MAC/archive/refs/tags/v1.0.0.tar.gz"
  version "1.0.0"
  license "MIT"
  head "https://github.com/Bornanaj/SSMS_MAC.git", branch: "main"

  depends_on macos: :sonoma
  depends_on xcode: ["15.0", :build]

  def install
    system "./Scripts/build-app.sh", "release"
    prefix.install "build/SSMS for Mac.app"
    bin.write_exec_script "#{prefix}/SSMS for Mac.app/Contents/MacOS/SSMS for Mac"
  end

  def caveats
    <<~EOS
      The app was compiled on this machine, so macOS opens it without a Gatekeeper
      prompt. Link it into /Applications with:

        ln -sfn "#{prefix}/SSMS for Mac.app" "/Applications/SSMS for Mac.app"
    EOS
  end

  test do
    assert_predicate prefix/"SSMS for Mac.app/Contents/MacOS/SSMS for Mac", :executable?
  end
end
