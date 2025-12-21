#[cfg(target_os = "windows")]
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_CAPITAL, VK_CONTROL, VK_ESCAPE, VK_F1, VK_F10, VK_F11, VK_F12, VK_F2,
    VK_F3, VK_F4, VK_F5, VK_F6, VK_F7, VK_F8, VK_F9, VK_LWIN, VK_MENU, VK_OEM_3, VK_SHIFT,
    VK_SPACE, VK_TAB, VIRTUAL_KEY,
};

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError};
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

use crate::config::settings::{HotkeyBinding, KeyCode};
use crate::get_pipeline;

#[derive(Debug, thiserror::Error)]
pub enum HotkeyError {
    #[error("Failed to start hotkey listener: {0}")]
    Start(String),
}

/// 将 KeyCode 转换为 Windows Virtual Key Code
#[cfg(target_os = "windows")]
fn keycode_to_vk(key: &KeyCode) -> VIRTUAL_KEY {
    match key {
        // 修饰键
        KeyCode::Alt => VK_MENU,
        KeyCode::Control => VK_CONTROL,
        KeyCode::Shift => VK_SHIFT,
        KeyCode::Meta => VK_LWIN,

        // 功能键
        KeyCode::F1 => VK_F1,
        KeyCode::F2 => VK_F2,
        KeyCode::F3 => VK_F3,
        KeyCode::F4 => VK_F4,
        KeyCode::F5 => VK_F5,
        KeyCode::F6 => VK_F6,
        KeyCode::F7 => VK_F7,
        KeyCode::F8 => VK_F8,
        KeyCode::F9 => VK_F9,
        KeyCode::F10 => VK_F10,
        KeyCode::F11 => VK_F11,
        KeyCode::F12 => VK_F12,

        // 字母键 (A-Z = 0x41-0x5A)
        KeyCode::KeyA => VIRTUAL_KEY(0x41),
        KeyCode::KeyB => VIRTUAL_KEY(0x42),
        KeyCode::KeyC => VIRTUAL_KEY(0x43),
        KeyCode::KeyD => VIRTUAL_KEY(0x44),
        KeyCode::KeyE => VIRTUAL_KEY(0x45),
        KeyCode::KeyF => VIRTUAL_KEY(0x46),
        KeyCode::KeyG => VIRTUAL_KEY(0x47),
        KeyCode::KeyH => VIRTUAL_KEY(0x48),
        KeyCode::KeyI => VIRTUAL_KEY(0x49),
        KeyCode::KeyJ => VIRTUAL_KEY(0x4A),
        KeyCode::KeyK => VIRTUAL_KEY(0x4B),
        KeyCode::KeyL => VIRTUAL_KEY(0x4C),
        KeyCode::KeyM => VIRTUAL_KEY(0x4D),
        KeyCode::KeyN => VIRTUAL_KEY(0x4E),
        KeyCode::KeyO => VIRTUAL_KEY(0x4F),
        KeyCode::KeyP => VIRTUAL_KEY(0x50),
        KeyCode::KeyQ => VIRTUAL_KEY(0x51),
        KeyCode::KeyR => VIRTUAL_KEY(0x52),
        KeyCode::KeyS => VIRTUAL_KEY(0x53),
        KeyCode::KeyT => VIRTUAL_KEY(0x54),
        KeyCode::KeyU => VIRTUAL_KEY(0x55),
        KeyCode::KeyV => VIRTUAL_KEY(0x56),
        KeyCode::KeyW => VIRTUAL_KEY(0x57),
        KeyCode::KeyX => VIRTUAL_KEY(0x58),
        KeyCode::KeyY => VIRTUAL_KEY(0x59),
        KeyCode::KeyZ => VIRTUAL_KEY(0x5A),

        // 数字键 (0-9 = 0x30-0x39)
        KeyCode::Digit0 => VIRTUAL_KEY(0x30),
        KeyCode::Digit1 => VIRTUAL_KEY(0x31),
        KeyCode::Digit2 => VIRTUAL_KEY(0x32),
        KeyCode::Digit3 => VIRTUAL_KEY(0x33),
        KeyCode::Digit4 => VIRTUAL_KEY(0x34),
        KeyCode::Digit5 => VIRTUAL_KEY(0x35),
        KeyCode::Digit6 => VIRTUAL_KEY(0x36),
        KeyCode::Digit7 => VIRTUAL_KEY(0x37),
        KeyCode::Digit8 => VIRTUAL_KEY(0x38),
        KeyCode::Digit9 => VIRTUAL_KEY(0x39),

        // 特殊键
        KeyCode::Space => VK_SPACE,
        KeyCode::Tab => VK_TAB,
        KeyCode::CapsLock => VK_CAPITAL,
        KeyCode::Escape => VK_ESCAPE,
        KeyCode::Backquote => VK_OEM_3,
    }
}

/// 检查按键是否按下
#[cfg(target_os = "windows")]
fn is_key_down(vk: VIRTUAL_KEY) -> bool {
    let state = unsafe { GetAsyncKeyState(vk.0 as i32) };
    (state as u16 & 0x8000) != 0
}

/// 检查修饰键是否全部按下
#[cfg(target_os = "windows")]
fn check_modifiers(modifiers: &[KeyCode]) -> bool {
    modifiers.iter().all(|m| is_key_down(keycode_to_vk(m)))
}

/// 启动 Windows 快捷键监听
#[cfg(target_os = "windows")]
pub fn start_listener(
    app_handle: AppHandle,
    binding: HotkeyBinding,
    stop_rx: Receiver<()>,
) -> Result<(), HotkeyError> {
    let is_key_pressed = Arc::new(AtomicBool::new(false));
    let is_recording = Arc::new(AtomicBool::new(false));

    let main_vk = keycode_to_vk(&binding.key);

    tracing::info!(
        "Starting Windows hotkey listener for: {:?} (vk: {:?})",
        binding,
        main_vk
    );

    loop {
        // 检查是否收到停止信号
        match stop_rx.try_recv() {
            Ok(_) | Err(TryRecvError::Disconnected) => {
                tracing::info!("Windows hotkey listener stopped");
                break;
            }
            Err(TryRecvError::Empty) => {}
        }

        // 检查主键状态
        let main_key_down = is_key_down(main_vk);

        // 检查修饰键状态
        let modifiers_down = check_modifiers(&binding.modifiers);

        // 组合判断：主键按下 + 所有修饰键按下
        let hotkey_active = main_key_down && modifiers_down;

        let was_pressed = is_key_pressed.load(Ordering::SeqCst);

        if hotkey_active && !was_pressed {
            // 快捷键激活
            is_key_pressed.store(true, Ordering::SeqCst);

            if !is_recording.load(Ordering::SeqCst) {
                is_recording.store(true, Ordering::SeqCst);
                tracing::info!("Hotkey pressed - starting recording");
                start_recording(&app_handle);
            }
        } else if !hotkey_active && was_pressed {
            // 快捷键释放 (主键释放或任一修饰键释放)
            is_key_pressed.store(false, Ordering::SeqCst);

            if is_recording.load(Ordering::SeqCst) {
                is_recording.store(false, Ordering::SeqCst);
                tracing::info!("Hotkey released - stopping recording");

                let app_handle_clone = app_handle.clone();
                thread::spawn(move || {
                    stop_recording(&app_handle_clone);
                });
            }
        }

        // 短暂休眠以减少 CPU 使用
        thread::sleep(Duration::from_millis(10));
    }

    Ok(())
}

#[cfg(not(target_os = "windows"))]
pub fn start_listener(
    _app_handle: AppHandle,
    _binding: HotkeyBinding,
    _stop_rx: std::sync::mpsc::Receiver<()>,
) -> Result<(), HotkeyError> {
    Err(HotkeyError::Start(
        "Windows hotkey not supported on this platform".to_string(),
    ))
}

fn start_recording(app_handle: &AppHandle) {
    let _ = app_handle.emit("recording-started", ());

    if let Some(pipeline) = get_pipeline() {
        if let Err(e) = pipeline.start_recording() {
            tracing::error!("Failed to start recording: {}", e);
            let _ = app_handle.emit("processing-error", e.to_string());
        }
    }
}

fn stop_recording(app_handle: &AppHandle) {
    let _ = app_handle.emit("recording-stopped", ());

    if let Some(pipeline) = get_pipeline() {
        let app_handle_clone = app_handle.clone();

        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                match pipeline.stop_and_process(None).await {
                    Ok(_) => {
                        let _ = app_handle_clone.emit("processing-complete", ());
                    }
                    Err(e) => {
                        tracing::error!("Processing error: {}", e);
                        let _ = app_handle_clone.emit("processing-error", e.to_string());
                    }
                }
            });
    }
}
