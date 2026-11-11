# Portfolio release checks

## Evidence from the current development environment

The current development host is macOS ARM64. The API suite uses a fixture subprocess, while browser tests use live Sinatra/Vite servers and that same fixture. These checks cannot establish Windows compilation or WIC codec correctness.

Local checks to run before release:

```sh
cd backend
bundle exec ruby test/server_test.rb
cd ../frontend
npm ci
npm run build
npx playwright install chromium
npm test
npm audit
```

The test suite covers partial-batch downloads, ZIP contents, duplicate POST isolation and queue deduplication, subprocess crash/timeout/malformed metadata/missing output, startup recovery and exclusive storage locking, strict settings, temporary-file cleanup, and file/path boundaries. Browser checks cover duplicate clicks, HTTP downloads, retrying polling failures, refresh recovery, stale jobs, and unavailable storage. The fixture does not produce real image data.

## Local results (2026-11-10)

Executed on macOS ARM64 with Ruby 3.3.5 and Node 22.16.0:

- API reliability suite: **13 tests, 280 assertions, zero failures/errors/skips**.
- Chromium suite: **6 tests passed**, including live HTTP uploads/downloads with the fixture processor.
- React/Vite production build: passed.
- npm dependency audit: zero reported vulnerabilities at the time of the check (not a security certification).
- Ruby 3.3 syntax checks and workflow YAML parsing: passed.
- Six PowerShell scripts parsed with PowerShell 7.6.8 on macOS: passed. This does not execute GDI+, MSVC, or WIC, or establish Windows PowerShell runtime compatibility.
- `git diff --check`: passed.

No real Windows processing or benchmark result is included in these local results.

## Required Windows evidence

Push the reviewed changes to GitHub and inspect the [Verify workflow](../.github/workflows/verify.yml). A workflow file by itself is not evidence that it passed. No Windows execution has been performed or observed for this working tree in the current session.

The `native-windows` job must succeed on the exact release commit:

1. MSVC x64 configure/build on Windows Server 2022.
2. Real PNG/JPEG/BMP/TIFF conversions, actual format and decoder validation, dimensions, quality endpoints and middle value, Unicode paths, invalid input and overwrite protection.
3. API fixture reliability tests on Windows as well as Linux.
4. Real-native Sinatra upload → queue → WIC processing → individual/ZIP download checks, including partial failure. Downloads are independently decoded with GDI+.
5. Native benchmark report uploaded for that commit, with hardware and hashes.

Run the same scripts manually on Windows 10/11 before describing consumer desktop Windows as manually tested. Open the React UI and inspect comparison/download behavior with a JPEG, transparent PNG, BMP, and TIFF. Confirm that a TIFF preview fallback remains usable. This manual check supplements CI rather than replacing it.

## Remaining decisions and limitations

- A successful Windows run is the main unresolved release gate. Until then, describe native support as implemented and awaiting verification.
- Choose a repository license. None has been inferred for the owner; a public repository alone does not grant an open-source license.
- Do not publish private user images, storage, test traces containing personal data, local paths, or credentials. Generated data and build/test artifacts are ignored by Git. Review the final staged diff before pushing.
- The service remains local and single-user. Authentication, public hosting, multi-process/distributed queues, automatic retention, EXIF/color preservation, multipage TIFFs, and broad browser coverage are outside this release's scope. These limitations are described in the README and should remain visible in portfolio claims.
- Duplicate UI clicks are suppressed; arbitrary repeated POSTs create isolated new jobs. A retry after a lost upload response can therefore duplicate work. There is no API idempotency promise.
- Interrupted jobs fail explicitly after restart. Successful files remain downloadable; pending files must be resubmitted. Completed originals/outputs need manual retention management.

After all checks pass, link the successful Actions run and its benchmark artifact in the release notes. Quote measured benchmarks with their environment and scope. There is no need to replace Sinatra, WIC, or the filesystem queue to present this project honestly.
