# Third-party runtime assets

- `web/webgazer.js`: Brown HCI Group WebGazer, copyright 2016–2020; the upstream GPLv3 notice and bundled dependency notices remain in the file. This is the local-model variant already present in OcuTrain; the OcuDrive source does not remove its notices.
- `web/webgazer-*-model.json` and `web/webgazer-*-weights.bin`: TensorFlow.js BlazeFace / FaceMesh assets vendored with the same OcuTrain WebGazer runtime. Their use and redistribution remain subject to the corresponding upstream model and dependency terms.
- `native/tobii_stream_engine.dll`: existing Tobii Stream Engine binary from the user's OcuTrain workspace. The manufacturer's SDK terms apply. OcuDrive does not grant additional rights to the binary.
- Ganzin Sol SDK: not supplied by the available local files. Obtain the matching original Python 3.12 SDK wheel through the Chronus Remote Browser and keep its license and dependency notices with any complete build. The bridge does not substitute a package of a similar name.

The actual device drivers and external Tobii Experience / Chronus calibration applications remain separate manufacturer installations. Tests using a browser inference fixture do not establish hardware accuracy.
