FROM ghcr.io/osgeo/gdal:ubuntu-full-3.7.3

# Don't use old pygeos
ENV USE_PYGEOS=0

RUN apt-get update && apt-get install -y \
    python3-pip \
    python3-dev \
    git \
    ca-certificates \
    build-essential \
    && apt-get autoclean \
    && apt-get autoremove \
    && rm -rf /var/lib/{apt,dpkg,cache,log}

# Set up pip and upgrade it
RUN pip3 install --upgrade pip setuptools wheel
# Install rasterio here, because it take a long time
RUN pip3 install rasterio --no-binary rasterio
# Now install all the normal python dependencies
ADD requirements.txt /tmp/requirements.txt
RUN pip3 install -r /tmp/requirements.txt

ADD ghrsst_cogger.py /code/ghrsst_cogger.py

WORKDIR /code

# Set runtime interface client as default command for the container runtime
ENTRYPOINT [ "python", "-m", "awslambdaric" ]

# Pass the name of the function handler as an argument to the runtime
CMD [ "ghrsst_cogger.lambda_handler" ]
