use super::*;
fn engine() -> PiRuntime {
    PiRuntime::new(RuntimeSpec::pi(), 0, "model", "native-context", 1).unwrap()
}
fn call() -> NativeCall {
    NativeCall {
        round_id: "round-0".into(),
        round_index: 0,
        call_id: "call-1".into(),
        name: "read_file".into(),
        arguments_sha256: "a".repeat(64),
    }
}
fn receipt(call: &NativeCall, outcome: &str) -> Value {
    json!({"schema_version":1,"call_id":call.call_id,"name":call.name,"arguments_sha256":call.arguments_sha256,"result_sha256":"b".repeat(64),"outcome":outcome})
}
#[test]
fn actual_pi_drives_model_tool_and_next_model() {
    let mut engine = engine();
    assert_eq!(engine.admit_model(0, &json!({})).unwrap(), Admission::Allow);
    let call = call();
    engine
        .model_result(0, "tool_batch", None, &[call.clone()], None)
        .unwrap();
    assert_eq!(
        engine.admit_tool(&call, &json!({})).unwrap(),
        Admission::Allow
    );
    engine.tool_result(&call, &receipt(&call, "ok")).unwrap();
    assert_eq!(engine.admit_model(1, &json!({})).unwrap(), Admission::Allow);
    engine
        .model_result(1, "final", Some("真实结果"), &[], None)
        .unwrap();
    let state = engine.state().unwrap();
    assert!(state.done);
    assert!(state.error.is_none());
    assert!(state.events.contains(&"tool_execution_start".into()));
    assert!(state.events.contains(&"agent_end".into()));
    assert!(engine.memory_bytes() < 16 * 1024 * 1024);
}
#[test]
fn custom_hook_stops_before_a_native_effect_and_has_no_ambient_io() {
    let spec=RuntimeSpec::custom("Review", "{ beforeModel(c) { if(typeof fetch!=='undefined'||typeof require!=='undefined'||typeof process!=='undefined') throw Error('ambient IO'); return {stop:'Review first'}; } }").unwrap();
    let mut engine = PiRuntime::new(spec, 0, "model", "native", 1).unwrap();
    assert_eq!(
        engine.admit_model(0, &json!({})).unwrap(),
        Admission::Stop("Review first".into())
    );
    assert_eq!(
        engine.state().unwrap().intent,
        Some(Intent::Model { round_index: 0 })
    );
    engine.abort().unwrap();
    assert!(engine.state().unwrap().done);
}
#[test]
fn tool_policy_and_native_denial_are_not_fabricated_success() {
    let spec = RuntimeSpec::custom(
        "No writes",
        "{ beforeTool(c) { return c.name==='write_file' ? {stop:'No writes'} : {allow:true}; } }",
    )
    .unwrap();
    let mut engine = PiRuntime::new(spec, 0, "model", "native", 1).unwrap();
    let mut call = call();
    call.name = "write_file".into();
    engine
        .model_result(0, "tool_batch", None, &[call.clone()], None)
        .unwrap();
    assert_eq!(
        engine
            .admit_tool(&call, &json!({"name":"write_file"}))
            .unwrap(),
        Admission::Stop("No writes".into())
    );
    engine
        .tool_result(&call, &receipt(&call, "denied"))
        .unwrap();
    assert_eq!(
        engine.state().unwrap().intent,
        Some(Intent::Model { round_index: 1 })
    );
}
#[test]
fn identity_mismatch_cannot_advance_pi() {
    let mut e = engine();
    let c = call();
    e.model_result(0, "tool_batch", None, &[c.clone()], None)
        .unwrap();
    let mut wrong = c.clone();
    wrong.round_id = "other".into();
    assert!(e.admit_tool(&wrong, &json!({})).is_err());
    assert!(e.tool_result(&wrong, &receipt(&wrong, "ok")).is_err());
    assert_eq!(e.state().unwrap().intent.unwrap().call(), Some(c));
}
#[test]
fn malformed_and_unbounded_hooks_fail_closed() {
    for source in [
        "{other(){return {allow:true}}}",
        "{beforeModel(){while(true){} }}",
        "{beforeModel(){return {allow:false}}}",
        "{beforeModel(){Promise.resolve().then(()=>{});return {allow:true}}}",
    ] {
        let spec = RuntimeSpec::custom("Bad", source).unwrap();
        match PiRuntime::new(spec, 0, "model", "native", 1) {
            Err(_) => {}
            Ok(mut e) => assert!(e.admit_model(0, &json!({})).is_err()),
        }
    }
}
#[test]
fn runtime_source_integrity_and_versions_are_checked() {
    let mut s = RuntimeSpec::custom("Runtime", "{}").unwrap();
    if let RuntimeSpec::Custom { source, .. } = &mut s {
        source.push(' ')
    }
    assert!(s.validate().is_err());
    let unsupported = RuntimeSpec::Pi {
        abi: 1,
        pi_version: "9.0.0".into(),
    };
    assert!(unsupported.validate().is_ok());
    assert!(PiRuntime::new(unsupported, 0, "m", "ctx", 1).is_err());
}
