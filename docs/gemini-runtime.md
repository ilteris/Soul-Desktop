# Bundled Gemini Runtime

Soul-Desktop runs Gemini through a vendored Gemini CLI bundle instead of relying
on a global `gemini` install. This keeps ACP behavior and downstream patches
version-locked to the app.

## Runtime Resolution

Gemini provider spawning resolves in this order:

1. App bundle: `Contents/Resources/GeminiCLI/bundle/gemini.js`
2. `SOUL_GEMINI_LOCAL` development override
3. `gemini` on `PATH`

When the bundled runtime exists, changes in `~/Code/gemini-cli` are not visible
to Soul-Desktop until the runtime is re-vendored.

## Updating the Bundle

After changing Gemini CLI source:

```bash
cd /Users/ilteris/Code/Soul-Desktop
./scripts/vendor_gemini_cli.sh
```

The script:

1. runs `npm run bundle` in `/Users/ilteris/Code/gemini-cli`
2. copies the generated `bundle/` into `Vendor/GeminiCLI`
3. writes `Vendor/GeminiCLI/manifest.json` with the Gemini version and git SHA

`Vendor/GeminiCLI` is intentionally ignored by git. Rebuild it locally whenever
the pinned Gemini source changes.

## Verifying the Bundle

```bash
cat Vendor/GeminiCLI/manifest.json
node Vendor/GeminiCLI/bundle/gemini.js --version
rg "Routing Gemini native delegation through soul delegate|SOUL_DELEGATE_GEMINI_NATIVE|parentToolCallId" Vendor/GeminiCLI/bundle
```

The manifest SHA should match the intended Gemini CLI commit. For the Soul
delegate routing patch, the bundle must contain `SOUL_DELEGATE_GEMINI_NATIVE`,
`Routing Gemini native delegation through soul delegate`, and ACP
`parentToolCallId` propagation.

## Building Soul-Desktop

```bash
xcodebuild -project Soul-Desktop.xcodeproj \
  -scheme "Soul-Desktop Dev" \
  -configuration Debug \
  -destination "platform=macOS" \
  build
```

The Xcode copy phase copies `Vendor/GeminiCLI` into
`Soul-Desktop Dev.app/Contents/Resources/GeminiCLI`.

To verify the built app runtime:

```bash
APP="/Users/ilteris/Library/Developer/Xcode/DerivedData/Soul-Desktop-hcakcmmzirxnqodoybnyizcvvcmm/Build/Products/Debug/Soul-Desktop Dev.app"
cat "$APP/Contents/Resources/GeminiCLI/manifest.json"
node "$APP/Contents/Resources/GeminiCLI/bundle/gemini.js" --version
```

