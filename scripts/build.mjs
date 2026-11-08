import { spawn } from "node:child_process";
import { chmod, copyFile, cp, lstat, mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const dist = join(root, "dist");
const release = process.argv.includes("--release");
const stage = await mkdtemp(join(root, ".monkeytype-unoffical-build-"));

function run(file, args) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(file, args, { cwd: root, stdio: "inherit", shell: false });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (code === 0) resolveRun();
      else reject(new Error(`${file} failed (${signal || `exit ${code}`}).`));
    });
  });
}

// Sources and font licenses must stay inside the project. Reject symlinks rather
// than following them into arbitrary files or accidentally shipping a link out.
async function copyResource(source, destination) {
  const info = await lstat(source);
  if (info.isSymbolicLink()) throw new Error(`Refusing to package symbolic link: ${source}`);
  if (!info.isFile()) throw new Error(`Unsupported resource type: ${source}`);
  await mkdir(dirname(destination), { recursive: true });
  await copyFile(source, destination);
}

try {
  if (process.platform !== "darwin") throw new Error("Building the native helper requires macOS command-line tools.");
  const architecture = { arm64: "arm64", x64: "x86_64" }[process.arch];
  if (!architecture) throw new Error(`Unsupported macOS architecture: ${process.arch}`);

  const manifest = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
  const { scripts: _scripts, ...installedManifest } = manifest;
  const bundleVersion = manifest.version.split(/[+-]/, 1)[0];
  await writeFile(join(stage, "package.json"), `${JSON.stringify(installedManifest, null, 2)}\n`);
  await copyResource(join(root, "src", "extension", "start-typing-practice.js"), join(stage, "start-typing-practice.js"));
  await copyResource(join(root, "assets", "icon.svg"), join(stage, "assets", "icon.svg"));

  const app = join(stage, "assets", "monkeytype-unoffical.app");
  const contents = join(app, "Contents");
  const resources = join(contents, "Resources");
  const executable = join(contents, "MacOS", "monkeytype-unoffical");
  await mkdir(dirname(executable), { recursive: true });
  await copyResource(join(root, "src", "engine", "typing-session.js"), join(resources, "typing-session.js"));
  await copyResource(join(root, "assets", "fonts", "JetBrainsMono-Regular.ttf"), join(resources, "JetBrainsMono-Regular.ttf"));
  await copyResource(join(root, "assets", "fonts", "OFL.txt"), join(resources, "OFL.txt"));
  for (const name of await readdir(root)) {
    if (/^(LICENSE|NOTICE|COPYING)(\.|$)/i.test(name)) {
      await copyResource(join(root, name), join(resources, name));
    }
  }
  await writeFile(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>monkeytype-unoffical</string>
<key>CFBundleIdentifier</key><string>app.tinycast.typing-practice.helper</string>
<key>CFBundleName</key><string>monkeytype-unoffical</string>
<key>CFBundleDisplayName</key><string>monkeytype-unoffical</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${bundleVersion}</string>
<key>CFBundleVersion</key><string>${bundleVersion}</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>app.tinycast.typing-practice.helper</string>
<key>CFBundleURLSchemes</key><array><string>monkeytype-unoffical</string></array>
</dict></array>
</dict></plist>
`);
  const nativeSources = ["TypingPractice.swift", "NativeViews.swift", "NativeSmoke.swift", "PassageRenderer.swift", "TypingSession.swift", "PassageProvider.swift", "HostAppearance.swift"].map(name => join(root, "src", "native", name));
  const architectures = release ? ["arm64", "x86_64"] : [architecture];
  const binaries = architectures.map(arch => join(stage, `native-${arch}`));
  for (const [index, arch] of architectures.entries()) {
    await run("/usr/bin/xcrun", ["--sdk", "macosx", "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-O", "-parse-as-library", "-target", `${arch}-apple-macosx26.0`, "-framework", "AppKit", "-framework", "JavaScriptCore", "-framework", "CoreText", "-framework", "ScreenCaptureKit", ...nativeSources, "-o", binaries[index]]);
  }
  if (release) {
    await run("/usr/bin/lipo", ["-create", ...binaries, "-output", executable]);
    await Promise.all(binaries.map(binary => rm(binary)));
  } else {
    await rename(binaries[0], executable);
  }
  await chmod(executable, 0o755);
  await run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app]);
  // Publish only a complete bundle; a failed compilation leaves the last build intact.
  await rm(dist, { recursive: true, force: true });
  await rename(stage, dist);
  // Tinycast's GitHub installer runs npm build, then installs the checkout root.
  // Keep these generated files alongside dist/; never commit either build layout.
  const githubApp = join(root, "assets", "monkeytype-unoffical.app");
  await rm(githubApp, { recursive: true, force: true });
  await cp(join(dist, "assets", "monkeytype-unoffical.app"), githubApp, { recursive: true });
  await copyFile(join(dist, "start-typing-practice.js"), join(root, "start-typing-practice.js"));
  console.log(`Built ${join(dist, "assets", "monkeytype-unoffical.app")}\nGitHub installation layout ready. For local installation, add dist/ in Tinycast.`);

  if (release) {
    const archive = join(root, "release", `${manifest.name}-${manifest.version}-macos-universal.zip`);
    await mkdir(dirname(archive), { recursive: true });
    await run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", dist, archive]);
    console.log(`Release archive: ${archive}\nAd-hoc signed, not notarized. Extract and add the enclosed dist/ folder in Tinycast.`);
  }
} finally {
  await rm(stage, { recursive: true, force: true });
}
