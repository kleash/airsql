# AirSQL's Homebrew cask, modelled on AirSCP's in kleash/homebrew-tap. A template: release.yml fills in the version and
# the zip's SHA-256, drops these comment lines and writes it to kleash/homebrew-tap as Casks/airsql.rb.
cask "airsql" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/kleash/airsql/releases/download/v#{version}/AirSQL-#{version}.zip"
  name "AirSQL"
  desc "MySQL and MariaDB client with SSH tunnels, a data grid and schema tools"
  homepage "https://kleash.github.io/airsql/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "AirSQL.app"

  zap trash: [
    "~/Library/Application Support/AirSQL",
    "~/Library/Preferences/com.kleash.airsql.plist",
    "~/Library/Saved Application State/com.kleash.airsql.savedState",
  ]
end
