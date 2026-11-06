# GPUI distribution status

The previous app's TestFlight workflow has been retired with the React Native
application. It is not a release path for the GPUI target.

The supported GPUI scripts currently build development artifacts:

```sh
apps/gpui/scripts/build-ios.sh --simulator
apps/gpui/scripts/build-ios.sh --device --release
apps/gpui/scripts/build-android.sh --release
```

Native dependency preparation is required first; see the
[developer guide](development.md#ios-build-prerequisites). iOS outputs are
unsigned, and the Android release APK is unsigned. These scripts do not install,
sign, export, upload, or submit a release. The development application identifier
is `tech.zseven.rish.gpui`, with a separate container from older installations.

A GPUI distribution pipeline is still to be implemented and verified. It needs
a reviewed production identifier/data-migration plan, signing and entitlement
configuration, archive/export handling, versioning, simulator/device acceptance,
and App Store Connect processing verification. Task Live Activity integration
is also incomplete; old extension signing settings cannot establish support
in the new target.

Existing certificates, profiles, App Store records, or successful uploads of the
previous app are not GPUI release evidence. Keep signing material and provider
credentials outside the repository. Building an unsigned app, producing a
signed archive, uploading it, and Apple finishing processing are distinct
results; none should be reported as another.

The retired workflow and its historical setup notes remain available in Git
history. No GPUI signing, TestFlight upload, or store release is claimed here.
