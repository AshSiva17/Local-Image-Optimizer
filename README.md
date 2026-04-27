# Local Image Optimizer

A local Ruby + C++ + React image optimizer. Drop images into the React UI, send them to the Ruby API, process them with the native C++ optimizer, compare before/after, and download individual outputs or a batch archive.

## Stack

- `frontend/`: React + Vite UI
- `backend/`: Ruby API with file-backed jobs
- `native/`: C++ command-line optimizer using Windows Imaging Component

## Prerequisites

This workspace currently needs these tools installed on the machine:

- Ruby 3.2+
- Node.js 20+
- CMake 3.24+
- A Windows C++ compiler, such as Visual Studio Build Tools

## Quick Start

```powershell
# 1. Build the C++ optimizer
.\scripts\build-native.ps1

# 2. Install and run the Ruby API
cd backend
bundle install
bundle exec rackup -p 4567

# 3. Install and run the React UI
cd ../frontend
npm install
npm run dev
```

Open `http://localhost:5173`.

## What It Does

- Upload multiple PNG, JPEG, BMP, or TIFF files.
- Resize by max width and max height while preserving aspect ratio.
- Convert to JPEG, PNG, BMP, TIFF, or keep the source format when it is one of those formats.
- Tune output quality for lossy encoders.
- Store original and optimized image metadata per job.
- Compare original and optimized versions with an interactive split view.
- Download each optimized file or export the whole job as a zip.

## API

```http
POST /api/jobs
GET /api/jobs/:id
GET /api/files/:job_id/:kind/:filename
GET /api/jobs/:id/export
```

`POST /api/jobs` expects multipart form data:

- `images[]`: image files
- `max_width`: optional integer
- `max_height`: optional integer
- `format`: `keep`, `jpeg`, `png`, `bmp`, or `tiff`
- `quality`: integer 1-100

## Native CLI

```powershell
native\build\Release\image_optimizer.exe `
  --input sample.jpg `
  --output sample-optimized.jpg `
  --format jpeg `
  --max-width 1600 `
  --quality 82
```

The CLI writes JSON metadata to stdout and returns a non-zero exit code on processing errors.
