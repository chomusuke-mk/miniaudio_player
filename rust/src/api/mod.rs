pub mod player;
pub mod types;

#[cfg(not(target_family = "wasm"))]
flutter_rust_bridge::for_generated::lazy_static! {
    pub static ref FLUTTER_RUST_BRIDGE_HANDLER: flutter_rust_bridge::DefaultHandler<flutter_rust_bridge::for_generated::SimpleThreadPool> =
        flutter_rust_bridge::DefaultHandler::new_simple(Default::default());
}

#[cfg(target_family = "wasm")]
mod wasm_worker_handler {
    use flutter_rust_bridge::for_generated::wasm_bindgen::JsValue;
    use flutter_rust_bridge::for_generated::{
        BaseCodec, BaseThreadPool, Executor, NoOpErrorListener, SimpleAsyncRuntime, SimpleExecutor,
        SimpleHandler, TaskContext, TaskInfo, TaskRetFutTrait, TransferClosure,
    };
    use std::future::Future;

    /// Direct execution pool for a WASM module running inside a Dedicated Web Worker.
    #[derive(Default, Clone, Copy)]
    pub struct DirectWorkerPool;

    impl BaseThreadPool for DirectWorkerPool {
        fn execute(&self, _closure: TransferClosure<JsValue>) {}
    }

    /// Deterministic executor for message-driven Web Worker execution without `SharedArrayBuffer` or `setTimeout`.
    pub struct WasmWorkerExecutor {
        inner: SimpleExecutor<NoOpErrorListener, DirectWorkerPool, SimpleAsyncRuntime>,
    }

    impl WasmWorkerExecutor {
        pub fn new() -> Self {
            Self {
                inner: SimpleExecutor::new(NoOpErrorListener, DirectWorkerPool, SimpleAsyncRuntime),
            }
        }
    }

    impl Executor for WasmWorkerExecutor {
        fn execute_normal<Rust2DartCodec, TaskFn>(&self, task_info: TaskInfo, task: TaskFn)
        where
            TaskFn: FnOnce(TaskContext) -> Result<Rust2DartCodec::Message, Rust2DartCodec::Message>
                + Send
                + 'static,
            Rust2DartCodec: BaseCodec,
        {
            self.inner
                .execute_async::<Rust2DartCodec, _, _>(task_info, move |context| async move {
                    task(context)
                });
        }

        fn execute_sync<Rust2DartCodec, SyncTaskFn>(
            &self,
            task_info: TaskInfo,
            sync_task: SyncTaskFn,
        ) -> Rust2DartCodec::Message
        where
            SyncTaskFn: FnOnce() -> Result<Rust2DartCodec::Message, Rust2DartCodec::Message>,
            Rust2DartCodec: BaseCodec,
        {
            self.inner
                .execute_sync::<Rust2DartCodec, _>(task_info, sync_task)
        }

        fn execute_async<Rust2DartCodec, TaskFn, TaskRetFut>(
            &self,
            task_info: TaskInfo,
            task: TaskFn,
        ) where
            TaskFn: FnOnce(TaskContext) -> TaskRetFut + Send + 'static,
            TaskRetFut: Future<Output = Result<Rust2DartCodec::Message, Rust2DartCodec::Message>>
                + TaskRetFutTrait,
            Rust2DartCodec: BaseCodec,
        {
            self.inner
                .execute_async::<Rust2DartCodec, _, _>(task_info, task);
        }
    }

    pub type WasmWorkerHandler = SimpleHandler<WasmWorkerExecutor, NoOpErrorListener>;

    pub fn create_worker_handler() -> WasmWorkerHandler {
        SimpleHandler::new(WasmWorkerExecutor::new(), NoOpErrorListener)
    }
}

#[cfg(target_family = "wasm")]
flutter_rust_bridge::for_generated::lazy_static! {
    pub static ref FLUTTER_RUST_BRIDGE_HANDLER: wasm_worker_handler::WasmWorkerHandler =
        wasm_worker_handler::create_worker_handler();
}
