============
Installation
============

Docker
======

When running docker image, no special installation is needed -- the docker will automatically download the image if not present.

Just run ``docker run --rm -it -v $(pwd):/data -p 8080:8080 maptiler/tileserver-gl``.

Additional options (see :doc:`/usage`) can be passed to the TileServer GL by appending them to the end of this command. You can, for example, do the following:

* ``docker run ... maptiler/tileserver-gl --file my-tiles.mbtiles`` -- explicitly specify which mbtiles to use (if you have more in the folder)
* ``docker run ... maptiler/tileserver-gl --verbose`` -- to see the default config created automatically

Alpine image
------------

``Dockerfile.alpine`` builds an Alpine-based image with a much smaller attack surface than the
Ubuntu one. It serves the same endpoints, runs as the same ``node`` user (uid/gid 999) and takes
the same options, so it is a drop-in replacement.

Two things differ under the hood:

* **Rendering uses surfaceless EGL instead of GLX.** There is no X server in the image and no
  ``Xvfb`` in the entrypoint. Both paths rasterise in software through Mesa's llvmpipe, so output
  is unchanged; the X server was only ever there to give GLX something to attach to.
* **ICU is compiled into the renderer.** The upstream prebuilt ``mbgl.node`` is linked against
  Ubuntu 24.04's ``libicuuc.so.74`` and against glibc, which is what ties the published image to
  Ubuntu. The Alpine image builds MapLibre Native from source against musl with ICU vendored, so
  neither dependency remains.

Because that build takes 30-60 minutes it is not part of the image build. It runs once per
(MapLibre version x Node ABI x architecture) in ``.github/workflows/mbgl-prebuild.yml``, is
published to GHCR, and ``Dockerfile.alpine`` copies the artifact in::

  docker build -f Dockerfile.alpine -t tileserver-gl:alpine .

To build the renderer yourself instead of using the published artifact::

  docker build -f Dockerfile.mbgl -t tileserver-gl-mbgl:local .
  docker build -f Dockerfile.alpine --build-arg MBGL_IMAGE=tileserver-gl-mbgl:local -t tileserver-gl:alpine .

``docker/compare-images.sh`` runs two images side by side against the same data directory and
compares their responses -- byte-for-byte for vector, JSON and metadata endpoints, and pixel-by-pixel
for rendered tiles -- which is how the Alpine image is checked against the Ubuntu one::

  docker/compare-images.sh tileserver-gl:ubuntu tileserver-gl:alpine ./test_data

npm
===

npm is supported on the following platforms with `Native Dependencies <#id1>`_ installed.

- Operating systems:

  - Ubuntu 24.04 (x64/arm64)
  - macOS 15 (x64/arm64)
  - Windows (x64)

- Node.js 20,22,24
  
Install globally from npmjs.
------------------------------
::

  npm install -g tileserver-gl
  tileserver-gl

Install locally from source
-------------------
::

  git clone https://github.com/maptiler/tileserver-gl.git
  cd tileserver-gl
  npm install
  node .

Native dependencies
-------------------

Ubuntu 24.04 (x64/arm64)
~~~~~~~~~~~~~~~~~~~~~~~~~~
- apt install build-essential python3-setuptools pkg-config xvfb libglfw3-dev libuv1-dev libjpeg-turbo8 libicu-dev libcairo2-dev libpango1.0-dev libpng-dev libjpeg-dev libgif-dev librsvg2-dev librsvg2-dev libcurl4-openssl-dev libpixman-1-dev

MacOS 15 (x64/arm64)
~~~~~~~~~~~~~~~~~~~~~~
- brew install pkg-config cairo pango libpng jpeg giflib librsvg harfbuzz

Windows (x64)
~~~~~~~~~~~~~~~~~~~~~~~~~
- `Microsoft Visual C++ Redistributable <https://aka.ms/vs/17/release/vc_redist.x64.exe>`_

``tileserver-gl-light`` on npm
==============================

Alternatively, you can use ``tileserver-gl-light`` package instead, which is pure javascript (does not have any native dependencies) and can run anywhere, but does not contain rasterization features.
