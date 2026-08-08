{
  lib,
  rcodesign,
  src,
  swiftPackages,
}:

swiftPackages.stdenv.mkDerivation {
  pname = "sleepless";
  version = "1.2.7";

  inherit src;

  strictDeps = true;
  nativeBuildInputs = [
    swiftPackages.swift
    rcodesign
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    swiftc \
      -O \
      -swift-version 5 \
      -parse-as-library \
      -module-name Sleepless \
      -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker 26.0 \
      -framework AppKit \
      -framework ServiceManagement \
      App.swift \
      -o Sleepless

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    app="$out/Applications/Sleepless.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    install -m755 Sleepless "$app/Contents/MacOS/Sleepless"
    install -m644 Info.plist "$app/Contents/Info.plist"
    install -m644 assets/Sleepless.icns "$app/Contents/Resources/Sleepless.icns"

    runHook postInstall
  '';

  postFixup = ''
    ${lib.getExe rcodesign} sign "$out/Applications/Sleepless.app"
  '';

  meta = {
    description = "Menu-bar control for keeping a Mac awake with its lid closed";
    homepage = "https://github.com/bagbag/Sleepless";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
  };
}
