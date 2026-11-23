#pragma once
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <memory>
#include <optional>
#include <string>
#include <vector>

// Native Windows shell integration. Task text never enters the tray or registry.
class DesktopBridge {
 public:
  DesktopBridge(HWND window, flutter::BinaryMessenger* messenger,
                const std::vector<std::string>& arguments);
  ~DesktopBridge();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  static bool PrepareInstance(const std::vector<std::string>& arguments);
  static void RemoveNotifications();
 private:
  void Emit(const std::string& event);
  void Show();
  void RegisterShell();
  void SetStartup(bool enabled);
  HWND window_;
  bool quit_ = false;
  bool ready_ = false;
  bool tray_added_ = false;
  bool hotkey_registered_ = false;
  bool clipboard_listening_ = false;
  std::string initial_activation_;
  std::string diagnostic_stage_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
