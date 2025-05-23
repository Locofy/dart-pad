# Dart Formatter

## How it works

- This formatter is powered by the `dart_style` package to format Dart code using official Dart conventions.
- Upload the compiled file to a CDN
- Load the CDN URL in your builder or plugin (e.g., iframe or script tag)
- Use it as a global variable:

```js
window.dartFormatter.format("Dart Code");
```

## How to build

### Development

```bash
make -f Makefile.prod dev
```

- Output is not minified
- Useful for debugging and development
- Output file: `build/format.dev.js`

### Production

```bash
make -f Makefile.prod build VERSION=1
```

- Output is minified and compressed with Terser
- Replaces location.href with a fixed origin for sandboxed iframe use
- Output files:
  - Raw: `build/format.v1.min.js`
  - Minified: `build/format.v1.final.min.js`
- After build, upload the output file (e.g., format.v1.final.min.js) to CDN.

**Note**: We replace `self.location.href` with https://locofy.ai in the final compiled code.
This is required because when running in production/staging plugin mode, the iframe has an invalid base URI (data:).
If we don’t override this, Uri.base will resolve to a data:text/... URI, causing Dart’s formatter to throw `FormatException: Expecting '='`.
