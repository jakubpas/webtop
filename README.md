# Webtop Desktop

This repository contains a utility script to launch a containerized Linux desktop environment using Docker. It is specifically optimized for Google Cloud Shell and High-DPI displays.

## Features

- **High-DPI Optimized**: Pre-configured with CSS scaling and DPI adjustments to ensure the UI is readable on high-resolution screens (like MacBooks).
- **Aspect Ratio Corrected**: Default resolution is tuned to 1512x744 to match 2:1 aspect ratio displays without black borders.
- **Fast Startup**: Automatically detects if the Docker image is already loaded to skip the time-consuming `docker load` step.
- **Persistent Storage**: Mounts `~/webtop_data` to ensure your browser settings and files are saved across sessions.
- **Automatic Cleanup**: Forcefully removes old container instances and clears Chromium lock files to prevent "Profile in use" errors.

## Usage

To start the desktop with the default resolution (1512x744):

```bash
./desktop
```

To start with a custom resolution:

```bash
./desktop <width> <height>
```

Example for a standard 1080p-like feel:
```bash
./desktop 1920 1080
```

## Prerequisites

- Docker installed and running.
- A exported Docker image at `~/webtop_image.tar`.
- A data directory at `~/webtop_data`.
