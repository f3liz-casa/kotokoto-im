class KotokotoIm < Formula
  desc "macOS の入力ソースを 1 キーで切り替える、メニューバー常駐ツール"
  homepage "https://github.com/f3liz-casa/kotokoto-im"
  head "https://github.com/f3liz-casa/kotokoto-im.git", branch: "main"

  depends_on :macos
  depends_on xcode: ["14.0", :build]

  def install
    ENV["SWIFT_BUILD_FLAGS"] = "--disable-sandbox"
    system "scripts/bundle.sh"
    prefix.install "build/kotokoto-im.app"
    bin.install_symlink prefix/"kotokoto-im.app/Contents/MacOS/kotokoto-im"
  end

  def caveats
    <<~EOS
      メニューバーのアプリとして使うには、.app を起動します:
        open #{opt_prefix}/kotokoto-im.app

      初回はアクセシビリティ(場合により入力監視)の許可が必要です。
      再インストールすると署名が変わるので、許可をやり直してください:
        tccutil reset Accessibility casa.f3liz.kotokoto-im
    EOS
  end

  test do
    assert_match "kotokoto-im", shell_output("#{bin}/kotokoto-im --help 2>&1", 0..1)
  end
end
