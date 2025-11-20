//! Listeners and endpoints

use std::collections::HashMap;
use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::time::Duration;

use axum::Router;
use axum::response::*;
use bytesize::ByteSize;
use futures::channel::oneshot;
use futures::prelude::*;
use hyper_util::rt::TokioExecutor;
use hyper_util::rt::TokioIo;
use hyper_util::rt::TokioTimer;
use hyper_util::server::conn::auto::Builder;
use multimap::MultiMap;
#[cfg(unix)]
use tokio::net::UnixListener;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tokio_util::time::FutureExt;
use tower_service::Service;

use crate::ListenAddr;
use crate::axum_factory::ENDPOINT_CALLBACK;
use crate::axum_factory::connection_handle::ConnectionHandle;
use crate::axum_factory::utils::ConnectionInfo;
use crate::axum_factory::utils::InjectConnectionInfo;
use crate::configuration::Configuration;
use crate::http_server_factory::Listener;
use crate::http_server_factory::NetworkStream;
use crate::router::ApolloRouterError;
use crate::router_factory::Endpoint;
use crate::services::router::pipeline_handle::PipelineRef;

static MAX_FILE_HANDLES_WARN: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Debug)]
pub(crate) struct ListenAddrAndRouter(pub(crate) ListenAddr, pub(crate) Router);

#[derive(Debug)]
pub(crate) struct ListenersAndRouters {
    pub(crate) main: ListenAddrAndRouter,
    pub(crate) extra: MultiMap<ListenAddr, Router>,
}

/// Merging [`axum::Router`]`s that use the same path panics (yes it doesn't raise an error, it panics.)
///
/// In order to not crash the router if paths clash using hot reload, we make sure the configuration is consistent,
/// and raise an error instead.
pub(super) fn ensure_endpoints_consistency(
    configuration: &Configuration,
    endpoints: &MultiMap<ListenAddr, Endpoint>,
) -> Result<(), ApolloRouterError> {
    // check the main endpoint
    if let Some(supergraph_listen_endpoint) = endpoints.get_vec(&configuration.supergraph.listen)
        && supergraph_listen_endpoint
            .iter()
            .any(|e| e.path == configuration.supergraph.path)
        && let Some((ip, port)) = configuration.supergraph.listen.ip_and_port()
    {
        return Err(ApolloRouterError::SameRouteUsedTwice(
            ip,
            port,
            configuration.supergraph.path.clone(),
        ));
    }

    // check the extra endpoints
    let mut listen_addrs_and_paths = HashSet::new();
    for (listen, endpoints) in endpoints.iter_all() {
        for endpoint in endpoints {
            if let Some((ip, port)) = listen.ip_and_port()
                && !listen_addrs_and_paths.insert((ip, port, endpoint.path.clone()))
            {
                return Err(ApolloRouterError::SameRouteUsedTwice(
                    ip,
                    port,
                    endpoint.path.clone(),
                ));
            }
        }
    }
    Ok(())
}

pub(super) fn extra_endpoints(
    endpoints: MultiMap<ListenAddr, Endpoint>,
) -> MultiMap<ListenAddr, Router> {
    let mut mm: MultiMap<ListenAddr, axum::Router> = Default::default();
    mm.extend(endpoints.into_iter().map(|(listen_addr, e)| {
        (
            listen_addr,
            e.into_iter()
                .map(|e| {
                    let mut router = e.into_router();
                    if let Some(main_endpoint_layer) = ENDPOINT_CALLBACK.get() {
                        router = main_endpoint_layer(router);
                    }
                    router
                })
                .collect::<Vec<_>>(),
        )
    }));
    mm
}

/// Binding different listen addresses to the same port will "relax" the requirements, which
/// could result in a security issue:
/// If endpoint A is exposed to 127.0.0.1:4000/foo and endpoint B is exposed to 0.0.0.0:4000/bar
/// 0.0.0.0:4000/foo would be accessible.
///
/// `ensure_listenaddrs_consistency` makes sure listen addresses that bind to the same port
/// have the same IP:
/// 127.0.0.1:4000 and 127.0.0.1:4000 will not trigger an error
/// 127.0.0.1:4000 and 0.0.0.0:4001 will not trigger an error
///
/// 127.0.0.1:4000 and 0.0.0.0:4000 will trigger an error
pub(super) fn ensure_listenaddrs_consistency(
    configuration: &Configuration,
    endpoints: &MultiMap<ListenAddr, Endpoint>,
) -> Result<(), ApolloRouterError> {
    let mut all_ports = HashMap::new();
    if let Some((main_ip, main_port)) = configuration.supergraph.listen.ip_and_port() {
        all_ports.insert(main_port, main_ip);
    }

    if configuration.health_check.enabled
        && let Some((ip, port)) = configuration.health_check.listen.ip_and_port()
        && let Some(previous_ip) = all_ports.insert(port, ip)
        && ip != previous_ip
    {
        return Err(ApolloRouterError::DifferentListenAddrsOnSamePort(
            previous_ip,
            ip,
            port,
        ));
    }

    for addr in endpoints.keys() {
        if let Some((ip, port)) = addr.ip_and_port()
            && let Some(previous_ip) = all_ports.insert(port, ip)
            && ip != previous_ip
        {
            return Err(ApolloRouterError::DifferentListenAddrsOnSamePort(
                previous_ip,
                ip,
                port,
            ));
        }
    }

    Ok(())
}

pub(super) async fn get_extra_listeners(
    previous_listeners: Vec<(ListenAddr, Listener)>,
    mut extra_routers: MultiMap<ListenAddr, Router>,
) -> Result<Vec<((ListenAddr, Listener), axum::Router)>, ApolloRouterError> {
    let mut listeners_and_routers: Vec<((ListenAddr, Listener), axum::Router)> =
        Vec::with_capacity(extra_routers.len());

    // reuse previous extra listen addrs
    for (listen_addr, listener) in previous_listeners.into_iter() {
        if let Some(routers) = extra_routers.remove(&listen_addr) {
            listeners_and_routers.push((
                (listen_addr, listener),
                routers
                    .iter()
                    .fold(axum::Router::new(), |acc, r| acc.merge(r.clone())),
            ));
        }
    }

    // populate the new listen addrs
    for (listen_addr, routers) in extra_routers.into_iter() {
        // if we received a TCP listener, reuse it, otherwise create a new one
        #[cfg_attr(not(unix), allow(unused_mut))]
        let listener = match listen_addr.clone() {
            ListenAddr::SocketAddr(addr) => Listener::new_from_socket_addr(addr, None).await?,
            #[cfg(unix)]
            ListenAddr::UnixSocket(path) => Listener::Unix(
                UnixListener::bind(path).map_err(ApolloRouterError::ServerCreationError)?,
            ),
        };
        listeners_and_routers.push((
            (listen_addr, listener),
            routers
                .iter()
                .fold(axum::Router::new(), |acc, r| acc.merge(r.clone())),
        ));
    }

    Ok(listeners_and_routers)
}

// This macro unifies the logic tht deals with connections.
// Ideally this would be a function, but the generics proved too difficult to figure out.
macro_rules! handle_connection {
    ($connection:expr, $connection_handle:expr, $connection_shutdown:expr, $connection_shutdown_timeout:expr, $received_first_request:expr, $connection_id:expr) => {
        let connection = $connection;
        let mut connection_handle = $connection_handle;
        let connection_shutdown = $connection_shutdown;
        let connection_shutdown_timeout = $connection_shutdown_timeout;
        let received_first_request = $received_first_request;
        let connection_id = $connection_id;
        tokio::pin!(connection);
        tokio::select! {
            // the connection finished first
            res = &mut connection => {
                if let Err(err) = res {
                    // Log connection-level errors (HTTP/2 protocol errors, timeouts, etc.)
                    let error_string = err.to_string();
                    if error_string.contains("timeout") {
                        tracing::warn!(
                            connection_id = %connection_id,
                            error = %err,
                            "[LISTENER] Connection error - timeout (check header_read_timeout or network latency)"
                        );
                    } else if error_string.contains("max_header_list_size") || error_string.contains("header") {
                        tracing::warn!(
                            connection_id = %connection_id,
                            error = %err,
                            "[LISTENER] Connection error - likely 431 due to header size limit"
                        );
                    } else {
                        tracing::warn!(
                            connection_id = %connection_id,
                            error = %err,
                            "[LISTENER] Connection error"
                        );
                    }
                } else {
                    tracing::info!(
                        connection_id = %connection_id,
                        "[LISTENER] Connection closed successfully"
                    );
                }
            }
            // the shutdown receiver was triggered first,
            // so we tell the connection to do a graceful shutdown
            // on the next request, then we wait for it to finish
            _ = connection_shutdown.cancelled() => {
                connection_handle.shutdown();
                connection.as_mut().graceful_shutdown();
                // Only wait for the connection to close gracfully if we recieved a request.
                // On hyper 0.x awaiting the connection would potentially hang forever if no request was recieved.
                if received_first_request.load(Ordering::Relaxed) {
                    // The connection may still not shutdown so we apply a timeout from the configuration
                    // Connections stuck terminating will keep the pipeline and everything related to that pipeline
                    // in memory.

                    if let Err(_) = connection.timeout(connection_shutdown_timeout).await {
                        tracing::warn!(
                            timeout = connection_shutdown_timeout.as_secs(),
                            server.address = connection_handle.address.to_string(),
                            schema.id = connection_handle.pipeline_ref.schema_id,
                            config.hash = connection_handle.pipeline_ref.config_hash,
                            launch.id = connection_handle.pipeline_ref.launch_id,
                            "connection shutdown exceeded, forcing close",
                        );
                    }
                }
            }
        }
    };
}

#[allow(clippy::too_many_arguments)]
async fn process_error(io_error: std::io::Error) {
    match io_error.kind() {
        // this is already handled by mio and tokio
        //std::io::ErrorKind::WouldBlock => todo!(),

        // should be treated as EAGAIN
        // https://man7.org/linux/man-pages/man2/accept.2.html
        // Linux accept() (and accept4()) passes already-pending network
        // errors on the new socket as an error code from accept().  This
        // behavior differs from other BSD socket implementations.  For
        // reliable operation the application should detect the network
        // errors defined for the protocol after accept() and treat them
        // like EAGAIN by retrying.  In the case of TCP/IP, these are
        // ENETDOWN, EPROTO, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH,
        // EOPNOTSUPP, and ENETUNREACH.
        //
        // those errors are not supported though: needs the unstable io_error_more feature
        // std::io::ErrorKind::NetworkDown => todo!(),
        // std::io::ErrorKind::HostUnreachable => todo!(),
        // std::io::ErrorKind::NetworkUnreachable => todo!(),

        //ECONNABORTED
        std::io::ErrorKind::ConnectionAborted|
        //EINTR
        std::io::ErrorKind::Interrupted|
        // EINVAL
        std::io::ErrorKind::InvalidInput|
        std::io::ErrorKind::PermissionDenied |
        std::io::ErrorKind::TimedOut |
        std::io::ErrorKind::ConnectionReset|
        std::io::ErrorKind::NotConnected => {
            // the socket was invalid (maybe timedout waiting in accept queue, or was closed)
            // we should ignore that and get to the next one
        }

        // ignored errors, these should not happen with accept()
        std::io::ErrorKind::NotFound |
        std::io::ErrorKind::AddrInUse |
        std::io::ErrorKind::AddrNotAvailable |
        std::io::ErrorKind::BrokenPipe|
        std::io::ErrorKind::AlreadyExists |
        std::io::ErrorKind::InvalidData |
        std::io::ErrorKind::WriteZero |
        std::io::ErrorKind::Unsupported |
        std::io::ErrorKind::UnexpectedEof |
        std::io::ErrorKind::OutOfMemory => {
        }

        // EPROTO, EOPNOTSUPP, EBADF, EFAULT, EMFILE, ENOBUFS, ENOMEM, ENOTSOCK
        // We match on _ because max open file errors fall under ErrorKind::Uncategorized
        _ => {
            match io_error.raw_os_error() {
                Some(libc::EMFILE) | Some(libc::ENFILE) => {
                    tracing::error!(
                        "reached the max open file limit, cannot accept any new connection"
                    );
                    MAX_FILE_HANDLES_WARN.store(true, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(1)).await;
                }
                _ => {}
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) fn serve_router_on_listen_addr(
    pipeline_ref: Arc<PipelineRef>,
    address: ListenAddr,
    mut listener: Listener,
    connection_shutdown_timeout: Duration,
    router: axum::Router,
    opt_max_headers: Option<usize>,
    opt_max_buf_size: Option<ByteSize>,
    opt_http2_max_header_list_size: Option<ByteSize>,
    header_read_timeout: Duration,
    all_connections_stopped_sender: mpsc::Sender<()>,
) -> (impl Future<Output = Listener>, oneshot::Sender<()>) {
    let (shutdown_sender, shutdown_receiver) = oneshot::channel::<()>();
    // this server reproduces most of hyper::server::Server's behaviour
    // we select over the stop_listen_receiver channel and the listener's
    // accept future. If the channel received something or the sender
    // was dropped, we stop using the listener and send it back through
    // listener_receiver
    let server = async move {
        tokio::pin!(shutdown_receiver);

        let connection_shutdown = CancellationToken::new();

        loop {
            tokio::select! {
                _ = &mut shutdown_receiver => {
                    break;
                }
                res = listener.accept() => {
                    let app = router.clone();
                    let connection_shutdown = connection_shutdown.clone();
                    let connection_stop_signal = all_connections_stopped_sender.clone();
                    let address = address.clone();
                    let pipeline_ref = pipeline_ref.clone();

                    match res {
                        Ok(res) => {
                            if MAX_FILE_HANDLES_WARN.load(Ordering::SeqCst) {
                                tracing::info!("can accept connections again");
                                MAX_FILE_HANDLES_WARN.store(false, Ordering::SeqCst);
                            }

                            tokio::task::spawn(async move {
                                // this sender must be moved into the session to track that it is still running
                                let _connection_stop_signal = connection_stop_signal;
                                let connection_handle = ConnectionHandle::new(pipeline_ref, address);

                                match res {
                                    NetworkStream::Tcp(stream) => {
                                        let received_first_request = Arc::new(AtomicBool::new(false));
                                        let app = InjectConnectionInfo::new(app, ConnectionInfo {
                                            peer_address: stream.peer_addr().ok(),
                                            server_address: stream.local_addr().ok(),
                                        });
                                        let app = IdleConnectionChecker::new(received_first_request.clone(), app);

                                        stream
                                            .set_nodelay(true)
                                            .expect(
                                                "this should not fail unless the socket is invalid",
                                            );

                                        // Generate a unique connection ID for tracking (with tcp prefix)
                                        let connection_id = format!("tcp-{}", uuid::Uuid::new_v4());
                                        
                                        let tokio_stream = TokioIo::new(stream);
                                        let conn_id = connection_id.clone();
                                        let hyper_service = hyper::service::service_fn(move |request: http::Request<hyper::body::Incoming>| {
                                            let conn_id = conn_id.clone();
                                            // Log request at the lowest level (before any processing)
                                            // Clone the values we need before moving request
                                            let tid = request.headers().get("intuit_tid")
                                                .or_else(|| request.headers().get("x-request-id"))
                                                .and_then(|v| v.to_str().ok())
                                                .map(|s| s.to_string())
                                                .unwrap_or_else(|| "unknown".to_string());
                                            
                                            let total_header_size: usize = request.headers().iter()
                                                .map(|(name, value)| name.as_str().len() + value.len())
                                                .sum();
                                            
                                            let header_count = request.headers().len();
                                            let method = request.method().clone();
                                            let uri = request.uri().clone();
                                            
                                            // Collect header names and their sizes
                                            let header_details: Vec<String> = request.headers().iter()
                                                .map(|(name, value)| {
                                                    format!("{}:{}b", name.as_str(), name.as_str().len() + value.len())
                                                })
                                                .collect();
                                            let header_list = header_details.join(", ");
                                            
                                            tracing::info!(
                                                connection_id = %conn_id,
                                                tid = %tid,
                                                method = %method,
                                                uri = %uri,
                                                header_count = header_count,
                                                total_header_size = total_header_size,
                                                headers = %header_list,
                                                "[LISTENER] Request received at connection layer"
                                            );
                                            
                                            let fut = app.clone().call(request);
                                            async move {
                                                let result = fut.await;
                                                match result {
                                                    Ok(response) => {
                                                        tracing::info!(
                                                            connection_id = %conn_id,
                                                            tid = %tid,
                                                            status_code = response.status().as_u16(),
                                                            "[LISTENER] Response sent from connection layer"
                                                        );
                                                        Ok(response)
                                                    }
                                                    Err(err) => {
                                                        tracing::error!(
                                                            connection_id = %conn_id,
                                                            tid = %tid,
                                                            error = %err,
                                                            "[LISTENER] Error in connection layer"
                                                        );
                                                        Err(err)
                                                    }
                                                }
                                            }
                                        });

                                        let mut builder = Builder::new(TokioExecutor::new());
                                        
                                        // Configure HTTP/2 settings first (via http2() sub-builder)
                                        // The auto builder will use these settings when HTTP/2 is negotiated
                                        if let Some(max_header_list_size) = opt_http2_max_header_list_size {
                                            tracing::info!(
                                                max_header_list_size = %max_header_list_size,
                                                "[LISTENER] Configuring HTTP/2 max_header_list_size"
                                            );
                                            builder.http2().max_header_list_size(max_header_list_size.as_u64() as u32);
                                        }
                                        
                                        // For plain TCP, we can't detect HTTP/2 via ALPN (no TLS handshake)
                                        // The auto builder will detect HTTP/2 via the connection preface
                                        // Log that we're ready for both HTTP/1.1 and HTTP/2
                                        tracing::info!(
                                            connection_id = %connection_id,
                                            http2_max_header_list_size = ?opt_http2_max_header_list_size,
                                            "[LISTENER] New TCP connection - auto-detecting HTTP/1.1 or HTTP/2"
                                        );
                                        
                                        // Configure HTTP/1 settings
                                        let mut http_connection = builder.http1();
                                        let http_config = http_connection
                                            .keep_alive(true)
                                            .timer(TokioTimer::new())
                                            .header_read_timeout(header_read_timeout);
                                        
                                        // Apply HTTP/1-specific limits
                                        // Note: These will only apply if the connection uses HTTP/1.1
                                        // For HTTP/2 connections, max_header_list_size (configured above) will apply
                                        if let Some(max_headers) = opt_max_headers {
                                            tracing::info!(
                                                max_headers = max_headers,
                                                "[LISTENER] Configuring HTTP/1 max_headers limit (will apply only if HTTP/1.1 is detected)"
                                            );
                                            http_config.max_headers(max_headers);
                                        }
                                        if let Some(max_buf_size) = opt_max_buf_size {
                                            tracing::info!(
                                                max_buf_size = %max_buf_size,
                                                "[LISTENER] Configuring HTTP/1 max_buf_size limit (will apply only if HTTP/1.1 is detected)"
                                            );
                                            http_config.max_buf_size(max_buf_size.as_u64() as usize);
                                        }
                                        
                                        let connection = http_config
                                            .serve_connection_with_upgrades(tokio_stream, hyper_service);
                                        
                                        // Log when connection starts serving
                                        tracing::info!(
                                            connection_id = %connection_id,
                                            "[LISTENER] Connection ready to serve requests"
                                        );
                                        
                                        handle_connection!(connection, connection_handle, connection_shutdown, connection_shutdown_timeout, received_first_request, connection_id);
                                    }
                                    #[cfg(unix)]
                                    NetworkStream::Unix(stream) => {
                                        let received_first_request = Arc::new(AtomicBool::new(false));
                                        let app = IdleConnectionChecker::new(received_first_request.clone(), app);
                                        let tokio_stream = TokioIo::new(stream);
                                        let hyper_service = hyper::service::service_fn(move |request| {
                                            app.clone().call(request)
                                        });
                                        let mut builder = Builder::new(TokioExecutor::new());
                                        let mut http_connection = builder.http1();
                                        let http_config = http_connection
                                                         .keep_alive(true)
                                                         .timer(TokioTimer::new())
                                                         .header_read_timeout(header_read_timeout);
                                        if let Some(max_headers) = opt_max_headers {
                                            http_config.max_headers(max_headers);
                                        }

                                        if let Some(max_buf_size) = opt_max_buf_size {
                                            http_config.max_buf_size(max_buf_size.as_u64() as usize);
                                        }
                                        let connection = http_config.serve_connection_with_upgrades(tokio_stream, hyper_service);
                                        let connection_id = format!("unix-{}", uuid::Uuid::new_v4());
                                        handle_connection!(connection, connection_handle, connection_shutdown, connection_shutdown_timeout, received_first_request, connection_id);
                                    },
                                    NetworkStream::Tls(stream) => {
                                        let received_first_request = Arc::new(AtomicBool::new(false));
                                        let app = IdleConnectionChecker::new(received_first_request.clone(), app);

                                        stream.get_ref().0
                                            .set_nodelay(true)
                                            .expect(
                                                "this should not fail unless the socket is invalid",
                                            );

                                        // Generate a unique connection ID for tracking (with tls prefix)
                                        let connection_id = format!("tls-{}", uuid::Uuid::new_v4());
                                        
                                        let tokio_stream = TokioIo::new(stream);
                                        let conn_id = connection_id.clone();
                                        let hyper_service = hyper::service::service_fn(move |request: http::Request<hyper::body::Incoming>| {
                                            let conn_id = conn_id.clone();
                                            // Log request at the lowest level (before any processing)
                                            // Clone the values we need before moving request
                                            let tid = request.headers().get("intuit_tid")
                                                .or_else(|| request.headers().get("x-request-id"))
                                                .and_then(|v| v.to_str().ok())
                                                .map(|s| s.to_string())
                                                .unwrap_or_else(|| "unknown".to_string());
                                            
                                            let total_header_size: usize = request.headers().iter()
                                                .map(|(name, value)| name.as_str().len() + value.len())
                                                .sum();
                                            
                                            let header_count = request.headers().len();
                                            let method = request.method().clone();
                                            let uri = request.uri().clone();
                                            
                                            // Collect header names and their sizes
                                            let header_details: Vec<String> = request.headers().iter()
                                                .map(|(name, value)| {
                                                    format!("{}:{}b", name.as_str(), name.as_str().len() + value.len())
                                                })
                                                .collect();
                                            let header_list = header_details.join(", ");
                                            
                                            tracing::info!(
                                                connection_id = %conn_id,
                                                tid = %tid,
                                                method = %method,
                                                uri = %uri,
                                                header_count = header_count,
                                                total_header_size = total_header_size,
                                                headers = %header_list,
                                                "[LISTENER] Request received at connection layer"
                                            );
                                            
                                            let fut = app.clone().call(request);
                                            async move {
                                                let result = fut.await;
                                                match result {
                                                    Ok(response) => {
                                                        tracing::info!(
                                                            connection_id = %conn_id,
                                                            tid = %tid,
                                                            status_code = response.status().as_u16(),
                                                            "[LISTENER] Response sent from connection layer"
                                                        );
                                                        Ok(response)
                                                    }
                                                    Err(err) => {
                                                        tracing::error!(
                                                            connection_id = %conn_id,
                                                            tid = %tid,
                                                            error = %err,
                                                            "[LISTENER] Error in connection layer"
                                                        );
                                                        Err(err)
                                                    }
                                                }
                                            }
                                        });

                                        let mut builder = Builder::new(TokioExecutor::new());
                                        
                                        // Configure HTTP/2 settings first (via http2() sub-builder)
                                        // The auto builder will use these settings when HTTP/2 is negotiated
                                        if let Some(max_header_list_size) = opt_http2_max_header_list_size {
                                            tracing::info!(
                                                max_header_list_size = %max_header_list_size,
                                                "[LISTENER] Configuring HTTP/2 max_header_list_size"
                                            );
                                            builder.http2().max_header_list_size(max_header_list_size.as_u64() as u32);
                                        }
                                        
                                        // Detect HTTP/2 via ALPN
                                        let is_http2 = tokio_stream.inner().get_ref().1.alpn_protocol() == Some(&b"h2"[..]);
                                        tracing::info!(
                                            connection_id = %connection_id,
                                            is_http2 = is_http2,
                                            http2_max_header_list_size = ?opt_http2_max_header_list_size,
                                            "[LISTENER] New TLS connection - protocol detected via ALPN"
                                        );
                                        if is_http2 {
                                            builder = builder.http2_only();
                                        }
                                        
                                        // Configure HTTP/1 settings (note: calling http1() doesn't force HTTP/1 if http2_only() was called)
                                        let mut http_connection = builder.http1();
                                        let http_config = http_connection
                                            .keep_alive(true)
                                            .timer(TokioTimer::new())
                                            .header_read_timeout(header_read_timeout);
                                        
                                        // Apply HTTP/1-specific limits only for HTTP/1.1 connections
                                        // For HTTP/2, these limits don't apply - HTTP/2 uses max_header_list_size instead
                                        if !is_http2 {
                                            if let Some(max_headers) = opt_max_headers {
                                                tracing::info!(
                                                    max_headers = max_headers,
                                                    "[LISTENER] Applying HTTP/1 max_headers limit"
                                                );
                                                http_config.max_headers(max_headers);
                                            }
                                            if let Some(max_buf_size) = opt_max_buf_size {
                                                tracing::info!(
                                                    max_buf_size = %max_buf_size,
                                                    "[LISTENER] Applying HTTP/1 max_buf_size limit"
                                                );
                                                http_config.max_buf_size(max_buf_size.as_u64() as usize);
                                            }
                                        } else {
                                            tracing::info!("[LISTENER] HTTP/2 connection - skipping HTTP/1 limits");
                                        }
                                        
                                        let connection = http_config
                                            .serve_connection_with_upgrades(tokio_stream, hyper_service);
                                        
                                        // Log when connection starts serving
                                        tracing::info!(
                                            connection_id = %connection_id,
                                            "[LISTENER] Connection ready to serve requests"
                                        );
                                        
                                        handle_connection!(connection, connection_handle, connection_shutdown, connection_shutdown_timeout, received_first_request, connection_id);
                                    }
                                }
                            });
                        }
                        Err(e) => process_error(e).await
                    }
                }
            }
        }

        // the shutdown receiver was triggered so we break out of
        // the server loop, tell the currently active connections to stop
        // then return the TCP listen socket
        connection_shutdown.cancel();
        listener
    };
    (server, shutdown_sender)
}

#[derive(Clone)]
struct IdleConnectionChecker<S> {
    received_request: Arc<AtomicBool>,
    inner: S,
}

impl<S: Clone> IdleConnectionChecker<S> {
    fn new(b: Arc<AtomicBool>, service: S) -> Self {
        IdleConnectionChecker {
            received_request: b,
            inner: service,
        }
    }
}
impl<S, B> Service<http::Request<B>> for IdleConnectionChecker<S>
where
    S: Service<http::Request<B>>,
{
    type Response = <S as Service<http::Request<B>>>::Response;

    type Error = <S as Service<http::Request<B>>>::Error;

    type Future = <S as Service<http::Request<B>>>::Future;

    fn poll_ready(
        &mut self,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::result::Result<(), Self::Error>> {
        self.inner.poll_ready(cx)
    }

    fn call(&mut self, req: http::Request<B>) -> Self::Future {
        self.received_request.store(true, Ordering::Relaxed);
        self.inner.call(req)
    }
}

#[cfg(test)]
mod tests {
    use std::net::SocketAddr;
    use std::str::FromStr;
    use std::sync::Arc;

    use axum::BoxError;
    use tower::ServiceExt;
    use tower::service_fn;

    use super::*;
    use crate::axum_factory::tests::init_with_config;
    use crate::configuration::Sandbox;
    use crate::configuration::Supergraph;
    use crate::services::router;
    use crate::services::router::body;

    #[tokio::test]
    async fn it_makes_sure_same_listenaddrs_are_accepted() {
        let configuration = Configuration::fake_builder().build().unwrap();

        init_with_config(
            router::service::empty().await,
            Arc::new(configuration),
            MultiMap::new(),
        )
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn it_makes_sure_different_listenaddrs_but_same_port_are_not_accepted() {
        let configuration = Configuration::fake_builder()
            .supergraph(
                Supergraph::fake_builder()
                    .listen(SocketAddr::from_str("127.0.0.1:4010").unwrap())
                    .build(),
            )
            .sandbox(Sandbox::fake_builder().build())
            .build()
            .unwrap();

        let endpoint = service_fn(|req: router::Request| async move {
            Ok::<_, BoxError>(
                router::Response::http_response_builder()
                    .response(
                        http::Response::builder().body::<crate::services::router::Body>(
                            body::from_bytes("this is a test".to_string()),
                        )?,
                    )
                    .context(req.context)
                    .build()
                    .unwrap(),
            )
        })
        .boxed();

        let mut web_endpoints = MultiMap::new();
        web_endpoints.insert(
            SocketAddr::from_str("0.0.0.0:4010").unwrap().into(),
            Endpoint::from_router_service("/".to_string(), endpoint),
        );

        let error = init_with_config(
            router::service::empty().await,
            Arc::new(configuration),
            web_endpoints,
        )
        .await
        .unwrap_err();
        assert_eq!(
            "tried to bind 127.0.0.1 and 0.0.0.0 on port 4010",
            error.to_string()
        )
    }

    #[tokio::test]
    async fn it_makes_sure_extra_endpoints_cant_use_the_same_listenaddr_and_path() {
        let configuration = Configuration::fake_builder()
            .supergraph(
                Supergraph::fake_builder()
                    .listen(SocketAddr::from_str("127.0.0.1:4010").unwrap())
                    .build(),
            )
            .build()
            .unwrap();
        let endpoint = service_fn(|req: router::Request| async move {
            router::Response::http_response_builder()
                .response(
                    http::Response::builder().body::<crate::services::router::Body>(
                        body::from_bytes("this is a test".to_string()),
                    )?,
                )
                .context(req.context)
                .build()
        })
        .boxed();

        let mut mm = MultiMap::new();
        mm.insert(
            SocketAddr::from_str("127.0.0.1:4010").unwrap().into(),
            Endpoint::from_router_service("/".to_string(), endpoint),
        );

        let error = init_with_config(router::service::empty().await, Arc::new(configuration), mm)
            .await
            .unwrap_err();

        assert_eq!(
            "tried to register two endpoints on `127.0.0.1:4010/`",
            error.to_string()
        )
    }
}
