// Rish compatibility policy shared by browser WebGL and native OpenGL ES.
// The renderer's texture transport needs no storage buffers or compute work.
#[cfg(any(target_os = "android", test))]
use wgpu::{AdapterInfo, DeviceType};
use wgpu::{Backend, Backends, Features, Limits, PresentMode};

pub(crate) fn supported_present_mode(
    preferred: Option<PresentMode>,
    supported: &[PresentMode],
) -> PresentMode {
    preferred
        .filter(|mode| supported.contains(mode))
        .unwrap_or(PresentMode::Fifo)
}

pub(super) fn native_instance_backends() -> Backends {
    (Backends::VULKAN | Backends::GL).with_env()
}

// This is an observed Android emulator compatibility exception, not a
// blacklist of software/virtual Vulkan devices or a repair of the driver.
#[cfg(any(target_os = "android", test))]
pub(super) fn known_android_vulkan_adapters(adapters: &[AdapterInfo]) -> bool {
    !adapters.is_empty()
        && adapters.iter().all(|info| {
            info.backend == Backend::Vulkan
                && info.device_type == DeviceType::VirtualGpu
                && info.vendor == 0x1ae0
                && info.device == 0xc0de
                && info.name == "SwiftShader Device (LLVM 10.0.0)"
        })
}

#[cfg(any(target_os = "android", test))]
pub(super) fn android_default_backends(
    requested: Backends,
    backend_override: bool,
    device_override: bool,
    vulkan_adapters: &[AdapterInfo],
    gl_device_usable: bool,
) -> Backends {
    if !backend_override
        && !device_override
        && requested.contains(Backends::VULKAN | Backends::GL)
        && known_android_vulkan_adapters(vulkan_adapters)
        && gl_device_usable
    {
        requested.difference(Backends::VULKAN)
    } else {
        requested
    }
}

#[cfg(any(target_os = "android", test))]
pub(super) fn gl_renderer_limits_supported(available: &Limits) -> bool {
    required_limits(Backend::Gl, available.clone()).check_limits(available)
}

pub(super) fn uses_texture_instances(backend: Backend) -> bool {
    backend == Backend::Gl
}

pub(super) fn required_limits(backend: Backend, adapter_limits: Limits) -> Limits {
    let limits = if uses_texture_instances(backend) {
        Limits::downlevel_webgl2_defaults()
    } else {
        Limits::downlevel_defaults()
    };
    limits
        .using_resolution(adapter_limits.clone())
        .using_alignment(adapter_limits)
}

pub(super) fn dual_source_blending(backend: Backend, available: Features) -> bool {
    !uses_texture_instances(backend) && available.contains(Features::DUAL_SOURCE_BLENDING)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known_swiftshader() -> AdapterInfo {
        AdapterInfo {
            name: "SwiftShader Device (LLVM 10.0.0)".into(),
            vendor: 0x1ae0,
            device: 0xc0de,
            device_type: DeviceType::VirtualGpu,
            device_pci_bus_id: String::new(),
            driver: String::new(),
            driver_info: String::new(),
            backend: Backend::Vulkan,
            subgroup_min_size: 0,
            subgroup_max_size: 0,
            transient_saves_memory: false,
        }
    }

    #[test]
    fn android_uses_gl_only_for_the_observed_vulkan_signature_and_usable_gl() {
        let defaults = Backends::VULKAN | Backends::GL;
        let adapters = [known_swiftshader()];
        assert_eq!(
            android_default_backends(defaults, false, false, &adapters, true),
            Backends::GL
        );
        // GL compilation or enumeration alone cannot establish device support.
        assert_eq!(
            android_default_backends(defaults, false, false, &adapters, false),
            defaults
        );
    }

    #[test]
    fn android_preserves_empty_mixed_physical_and_unknown_vulkan_adapters() {
        let defaults = Backends::VULKAN | Backends::GL;
        let known = known_swiftshader();
        let mut physical = known.clone();
        physical.device_type = DeviceType::IntegratedGpu;
        let mut unknown = known.clone();
        unknown.name = "SwiftShader Device (LLVM 11.0.0)".into();
        let mut other_vendor = known.clone();
        other_vendor.vendor = 0x1234;
        let mut other_device = known.clone();
        other_device.device = 0x5678;
        let mut other_backend = known.clone();
        other_backend.backend = Backend::Gl;
        for adapters in [
            vec![],
            vec![known, physical.clone()],
            vec![physical],
            vec![unknown],
            vec![other_vendor],
            vec![other_device],
            vec![other_backend],
        ] {
            assert_eq!(
                android_default_backends(defaults, false, false, &adapters, true),
                defaults
            );
        }
    }

    #[test]
    fn android_never_rewrites_explicit_backend_or_device_selection() {
        let defaults = Backends::VULKAN | Backends::GL;
        let adapters = [known_swiftshader()];
        for (backends, backend_override, device_override) in [
            (defaults, true, false),
            (defaults, false, true),
            (defaults, true, true),
            (Backends::VULKAN, false, false),
            (Backends::GL, false, false),
        ] {
            assert_eq!(
                android_default_backends(
                    backends,
                    backend_override,
                    device_override,
                    &adapters,
                    true,
                ),
                backends
            );
        }
    }

    #[test]
    fn android_rejects_gl_with_zero_vertex_buffer_limits() {
        let defaults = Backends::VULKAN | Backends::GL;
        let adapters = [known_swiftshader()];
        let available = Limits::downlevel_webgl2_defaults();
        assert!(gl_renderer_limits_supported(&available));
        let unusable = Limits {
            max_vertex_buffers: 0,
            ..available
        };
        assert!(!gl_renderer_limits_supported(&unusable));
        assert_eq!(
            android_default_backends(
                defaults,
                false,
                false,
                &adapters,
                gl_renderer_limits_supported(&unusable),
            ),
            defaults
        );
    }

    #[test]
    fn fifo_only_surface_rejects_mailbox_on_startup_and_replacement() {
        let modes = [PresentMode::Fifo];
        let initial = supported_present_mode(Some(PresentMode::Mailbox), &modes);
        assert_eq!(initial, PresentMode::Fifo);
        let replacement =
            supported_present_mode(Some(PresentMode::Mailbox).or(Some(initial)), &modes);
        assert_eq!(replacement, PresentMode::Fifo);
    }

    #[test]
    fn replacement_preserves_a_supported_preference_but_rechecks_old_modes() {
        let mailbox_surface = [PresentMode::Fifo, PresentMode::Mailbox];
        let initial = supported_present_mode(Some(PresentMode::Mailbox), &mailbox_surface);
        assert_eq!(initial, PresentMode::Mailbox);
        assert_eq!(
            supported_present_mode(Some(initial), &mailbox_surface),
            initial
        );
        // The same renderer may be attached to a more constrained new surface.
        assert_eq!(
            supported_present_mode(Some(initial), &[PresentMode::Fifo]),
            PresentMode::Fifo
        );
        assert_eq!(
            supported_present_mode(None, &mailbox_surface),
            PresentMode::Fifo
        );
    }

    #[test]
    fn native_instance_override_is_scoped_to_the_process() {
        const EXPECTED: &str = "RISH_TEST_EXPECTED_WGPU_BACKENDS";
        if let Ok(expected) = std::env::var(EXPECTED) {
            assert_eq!(
                native_instance_backends().bits(),
                expected.parse::<u32>().unwrap()
            );
            return;
        }
        // Exercise the real wgpu environment parser in a fresh process. Never
        // mutate this test runner's environment while other tests may run.
        let module = module_path!().split_once("::").unwrap().1;
        let test = format!("{module}::native_instance_override_is_scoped_to_the_process");
        for (value, expected) in [
            (None, Backends::VULKAN | Backends::GL),
            (Some("gl"), Backends::GL),
            (Some("vulkan"), Backends::VULKAN),
        ] {
            let mut child = std::process::Command::new(std::env::current_exe().unwrap());
            child
                .args(["--exact", &test])
                .env(EXPECTED, expected.bits().to_string());
            if let Some(value) = value {
                child.env("WGPU_BACKEND", value);
            } else {
                child.env_remove("WGPU_BACKEND");
            }
            let output = child.output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(String::from_utf8_lossy(&output.stdout).contains("1 passed"));
        }
    }

    #[test]
    fn gl_accepts_an_adapter_without_compute_or_storage_buffers() {
        let available = Limits::downlevel_webgl2_defaults();
        let requested = required_limits(Backend::Gl, available.clone());
        assert!(requested.check_limits(&available));
        assert_eq!(requested.max_compute_workgroups_per_dimension, 0);
        assert_eq!(requested.max_compute_invocations_per_workgroup, 0);
        assert_eq!(requested.max_storage_buffers_per_shader_stage, 0);
        assert_eq!(requested.max_storage_buffer_binding_size, 0);
        // Lowering limits alone is insufficient: the render path must also
        // stop creating storage bindings and use the existing texture shader.
        assert!(uses_texture_instances(Backend::Gl));
    }

    #[test]
    fn non_gl_backends_retain_storage_transport_and_downlevel_limits() {
        for backend in [
            Backend::Vulkan,
            Backend::Metal,
            Backend::Dx12,
            Backend::BrowserWebGpu,
        ] {
            let available = Limits::downlevel_defaults();
            let requested = required_limits(backend, available.clone());
            assert!(requested.check_limits(&available));
            assert_eq!(requested.max_compute_workgroups_per_dimension, 65_535);
            assert!(requested.max_storage_buffer_binding_size > 0);
            assert!(!uses_texture_instances(backend));
        }
    }

    #[test]
    fn gl_uses_the_adapters_resolution_and_buffer_alignment() {
        let available = Limits {
            max_texture_dimension_2d: 8_192,
            min_uniform_buffer_offset_alignment: 512,
            min_storage_buffer_offset_alignment: 512,
            ..Limits::downlevel_webgl2_defaults()
        };
        let requested = required_limits(Backend::Gl, available.clone());
        assert!(requested.check_limits(&available));
        assert_eq!(requested.max_texture_dimension_2d, 8_192);
        assert_eq!(requested.min_uniform_buffer_offset_alignment, 512);
        assert_eq!(requested.min_storage_buffer_offset_alignment, 512);
    }

    #[test]
    fn gl_never_requests_the_unused_dual_source_feature() {
        assert!(!dual_source_blending(
            Backend::Gl,
            Features::DUAL_SOURCE_BLENDING
        ));
        assert!(!dual_source_blending(Backend::Gl, Features::empty()));
        assert!(dual_source_blending(
            Backend::Vulkan,
            Features::DUAL_SOURCE_BLENDING
        ));
        assert!(!dual_source_blending(Backend::Vulkan, Features::empty()));
    }
}
