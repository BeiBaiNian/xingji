#include "desktop_bridge.h"
#include "resource.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <propkey.h>
#include <propvarutil.h>
#include <wtsapi32.h>
#include <dwmapi.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <array>
#include <filesystem>
#include <chrono>
#include <cstdio>
#include <set>
#include <stdexcept>
#include <sddl.h>

using flutter::EncodableValue;
using flutter::EncodableMap;
using flutter::EncodableList;
using namespace winrt::Windows::UI::Notifications;
namespace {
constexpr wchar_t kAppId[] = L"XingJi.Desktop";
// Protocol-only activation uses a stable stub CLSID on the shortcut. No COM
// server is registered: every toast and action carries a xingji:// URI.
constexpr wchar_t kToastClsid[] = L"{8D25B1F7-B60D-4633-8F3C-43EAEF890BD1}";
constexpr UINT kTray = WM_APP + 71;
constexpr int kHotkey = 71;
std::wstring instance_property;
HANDLE instance_mutex = nullptr;
std::wstring Executable() {
  wchar_t path[32768];
  GetModuleFileNameW(nullptr, path, 32768);
  return path;
}
std::string String(const EncodableMap& map, const char* name) {
  auto it = map.find(EncodableValue(name));
  return it == map.end() ? "" : std::get<std::string>(it->second);
}
int64_t Integer(const EncodableMap& map, const char* name) {
  const auto& v = map.at(EncodableValue(name));
  return std::holds_alternative<int64_t>(v) ? std::get<int64_t>(v) : std::get<int32_t>(v);
}
void SetRegistryString(HKEY root, const std::wstring& path, const wchar_t* name,
                       const std::wstring& value) {
  DWORD bytes = 0;
  if (RegGetValueW(root, path.c_str(), name, RRF_RT_REG_SZ, nullptr, nullptr, &bytes) == ERROR_SUCCESS) {
    std::vector<wchar_t> previous(bytes / sizeof(wchar_t) + 1, 0);
    if (RegGetValueW(root, path.c_str(), name, RRF_RT_REG_SZ, nullptr, previous.data(), &bytes) == ERROR_SUCCESS && value == previous.data()) return;
  }
  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(root, path.c_str(), 0, nullptr,
    REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) winrt::throw_hresult(HRESULT_FROM_WIN32(status));
  status = RegSetValueExW(key, name, 0, REG_SZ,
    reinterpret_cast<const BYTE*>(value.c_str()), static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) winrt::throw_hresult(HRESULT_FROM_WIN32(status));
}
winrt::Windows::Data::Xml::Dom::XmlDocument Document(const std::string& xml) {
  winrt::Windows::Data::Xml::Dom::XmlDocument doc;
  doc.LoadXml(winrt::to_hstring(xml));
  return doc;
}

const std::array<UINT, 3>& ClipboardImageFormats() {
  static const std::array<UINT, 3> formats = {
    RegisterClipboardFormatW(L"PNG"), CF_DIB, CF_DIBV5
  };
  return formats;
}

bool ClipboardHasImage() {
  for (const UINT format : ClipboardImageFormats()) {
    if (format && IsClipboardFormatAvailable(format)) return true;
  }
  return false;
}

EncodableValue ReadClipboardImage(HWND window) {
  if (!OpenClipboard(window)) throw std::runtime_error("剪贴板正在使用，请重试");
  struct ClipboardGuard { ~ClipboardGuard() { CloseClipboard(); } } guard;
  const auto& formats = ClipboardImageFormats();
  bool found_format = false;
  for (const UINT format : formats) {
    if (!format || !IsClipboardFormatAvailable(format)) continue;
    found_format = true;
    HGLOBAL handle = GetClipboardData(format);
    if (!handle) continue;
    const SIZE_T size = GlobalSize(handle);
    if (!size) continue;
    if (size > 32 * 1024 * 1024) throw std::runtime_error("请选择 32 MiB 以内的图片");
    const auto* data = static_cast<const uint8_t*>(GlobalLock(handle));
    if (!data) continue;
    struct MemoryGuard {
      HGLOBAL handle;
      ~MemoryGuard() { GlobalUnlock(handle); }
    } memory{handle};
    EncodableMap response;
    response[EncodableValue("format")] = EncodableValue(format == formats.front() ? "png" : "dib");
    response[EncodableValue("bytes")] = EncodableValue(std::vector<uint8_t>(data, data + size));
    return EncodableValue(std::move(response));
  }
  if (found_format) throw std::runtime_error("无法读取剪贴板图片，请重新复制后再试");
  return EncodableValue();
}
}

bool DesktopBridge::PrepareInstance(const std::vector<std::string>& arguments) {
  std::string profile = "default";
  for (const auto& arg : arguments) if (arg.rfind("--data-dir=", 0) == 0) profile = arg;
  instance_property = profile == "default" ? L"XingJi.Instance.default"
    : L"XingJi.Instance." + std::to_wstring(std::hash<std::string>{}(profile));
  // An instance under a development/sandbox account must not capture launches
  // from the real desktop user. Notification registration is per Windows user.
  HANDLE token = nullptr;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    if (IsTokenRestricted(token)) instance_property += L".restricted";
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
      LPWSTR sid = nullptr;
      if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sid)) {
        instance_property += L"." + std::wstring(sid);
        LocalFree(sid);
      }
    }
    DWORD integrity_size = 0;
    GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &integrity_size);
    std::vector<BYTE> integrity(integrity_size);
    if (GetTokenInformation(token, TokenIntegrityLevel, integrity.data(), integrity_size, &integrity_size)) {
      LPWSTR label = nullptr;
      if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_MANDATORY_LABEL*>(integrity.data())->Label.Sid, &label)) {
        instance_property += L"." + std::wstring(label);
        LocalFree(label);
      }
    }
    CloseHandle(token);
  }
  std::wstring mutex_name = L"Local\\" + instance_property;
  instance_mutex = CreateMutexW(nullptr, TRUE, mutex_name.c_str());
  if (GetLastError() != ERROR_ALREADY_EXISTS) return true;
  HWND existing = nullptr;
  EnumWindows([](HWND hwnd, LPARAM param) -> BOOL {
    if (GetPropW(hwnd, instance_property.c_str())) { *reinterpret_cast<HWND*>(param) = hwnd; return FALSE; }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&existing));
  if (existing) {
    std::string activation = "show";
    for (const auto& arg : arguments) if (arg.rfind("xingji://", 0) == 0) activation = arg;
    COPYDATASTRUCT data{};
    data.dwData = 0x584A;
    data.cbData = static_cast<DWORD>(activation.size() + 1);
    data.lpData = activation.data();
    DWORD_PTR ignored;
    SendMessageTimeoutW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
      SMTO_ABORTIFHUNG, 2000, &ignored);
    ShowWindow(existing, SW_RESTORE);
    SetForegroundWindow(existing);
  }
  return false;
}

void DesktopBridge::RemoveNotifications() {
  try {
    auto notifier = ToastNotificationManager::CreateToastNotifier(kAppId);
    for (const auto& item : notifier.GetScheduledToastNotifications()) notifier.RemoveFromSchedule(item);
    ToastNotificationManager::History().Clear(kAppId);
  } catch (...) { /* Uninstall also works when the OS has already removed identity. */ }
}

DesktopBridge::DesktopBridge(HWND window, flutter::BinaryMessenger* messenger,
    const std::vector<std::string>& arguments) : window_(window) {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  SetPropW(window_, instance_property.c_str(), reinterpret_cast<HANDLE>(1));
  BOOL dark = TRUE;
  DwmSetWindowAttribute(window_, 20, &dark, sizeof(dark));
  for (const auto& arg : arguments) if (arg.rfind("xingji://", 0) == 0) initial_activation_ = arg;
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
    messenger, "xingji/desktop", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      const auto& method = call.method_name();
      diagnostic_stage_ = method;
      const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      if (method == "initialize") {
        ready_ = true;
        RegisterShell();
        diagnostic_stage_ = "createNotifier";
        auto notifier = ToastNotificationManager::CreateToastNotifier(kAppId);
        // Unpackaged Win32 apps must send one toast before querying scheduled
        // notifications. Suppress it and remove it immediately from history.
        ToastNotification registration(Document(
          "<toast activationType=\"protocol\" launch=\"xingji://open\"><visual>"
          "<binding template=\"ToastGeneric\"><text>星记</text></binding>"
          "</visual><audio silent=\"true\"/></toast>"));
        registration.Tag(L"xj_registration");
        registration.Group(L"setup");
        registration.SuppressPopup(true);
        registration.ExpirationTime(winrt::clock::now() + std::chrono::seconds(15));
        diagnostic_stage_ = "registerNotification";
        notifier.Show(registration);
        diagnostic_stage_ = "removeRegistrationNotification";
        ToastNotificationManager::History().Remove(L"xj_registration", L"setup", kAppId);
        diagnostic_stage_ = "notificationSetting";
        const auto setting = notifier.Setting();
        EncodableMap response;
        response[EncodableValue("allowed")] = EncodableValue(setting == NotificationSetting::Enabled);
        response[EncodableValue("setting")] = EncodableValue(static_cast<int32_t>(setting));
        response[EncodableValue("activation")] = EncodableValue(initial_activation_);
        hotkey_registered_ = hotkey_registered_ || RegisterHotKey(window_, kHotkey, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'N') != 0;
        response[EncodableValue("hotkey")] = EncodableValue(hotkey_registered_);
        result->Success(EncodableValue(response));
      } else if (method == "clipboardImageStatus") {
        if (!clipboard_listening_) clipboard_listening_ = AddClipboardFormatListener(window_) != FALSE;
        EncodableMap status;
        status[EncodableValue("listening")] = EncodableValue(clipboard_listening_);
        status[EncodableValue("hasImage")] = EncodableValue(ClipboardHasImage());
        result->Success(EncodableValue(status));
      } else if (method == "readClipboardImage") {
        try {
          result->Success(ReadClipboardImage(window_));
        } catch (const std::runtime_error& e) {
          result->Error("clipboard_image", e.what());
        }
      } else if (method == "replaceSchedules") {
        auto notifier = ToastNotificationManager::CreateToastNotifier(kAppId);
        const auto& items = std::get<EncodableList>(args->at(EncodableValue("items")));
        std::set<std::string> desired, existing;
        for (const auto& value : items) desired.insert(String(std::get<EncodableMap>(value), "id"));
        auto scheduled = notifier.GetScheduledToastNotifications();
        for (const auto& item : scheduled) {
          const auto id = winrt::to_string(item.Id());
          if (desired.count(id)) existing.insert(id);
          else notifier.RemoveFromSchedule(item);
        }
        // Only remove old task generations; unrelated delivered reminders stay visible.
        const auto& removed = std::get<EncodableList>(args->at(EncodableValue("removeIds")));
        for (const auto& id : removed) {
          ToastNotificationManager::History().Remove(winrt::to_hstring(std::get<std::string>(id)), L"memo", kAppId);
        }
        for (const auto& value : items) {
          const auto& item = std::get<EncodableMap>(value);
          if (existing.count(String(item, "id"))) continue;
          const auto when = winrt::clock::from_time_t(Integer(item, "at") / 1000);
          ScheduledToastNotification toast(Document(String(item, "xml")), when);
          toast.Id(winrt::to_hstring(String(item, "id")));
          toast.Tag(winrt::to_hstring(String(item, "id")));
          toast.Group(L"memo");
          toast.ExpirationTime(when + std::chrono::minutes(5));
          notifier.AddToSchedule(toast);
        }
        result->Success(EncodableValue(static_cast<int32_t>(items.size())));
      } else if (method == "showNotification") {
        ToastNotification toast(Document(String(*args, "xml")));
        toast.Tag(winrt::to_hstring(String(*args, "id")));
        toast.Group(L"memo");
        ToastNotificationManager::CreateToastNotifier(kAppId).Show(toast);
        result->Success();
      } else if (method == "notificationState") {
        auto notifier = ToastNotificationManager::CreateToastNotifier(kAppId);
        EncodableMap response;
        response[EncodableValue("allowed")] = EncodableValue(notifier.Setting() == NotificationSetting::Enabled);
        response[EncodableValue("scheduled")] = EncodableValue(static_cast<int32_t>(notifier.GetScheduledToastNotifications().Size()));
        EncodableList ids;
        for (const auto& item : notifier.GetScheduledToastNotifications()) ids.push_back(EncodableValue(winrt::to_string(item.Id())));
        response[EncodableValue("ids")] = EncodableValue(ids);
        EncodableList delivered;
        try {
          for (const auto& item : ToastNotificationManager::History().GetHistory(kAppId)) delivered.push_back(EncodableValue(winrt::to_string(item.Tag())));
        } catch (...) { /* Some Windows policies do not expose notification history. */ }
        response[EncodableValue("delivered")] = EncodableValue(delivered);
        result->Success(EncodableValue(response));
      } else if (method == "theme") {
        BOOL dark = std::get<bool>(args->at(EncodableValue("dark"))) ? TRUE : FALSE;
        DwmSetWindowAttribute(window_, 20, &dark, sizeof(dark));
        result->Success();
      } else if (method == "startup") {
        SetStartup(std::get<bool>(args->at(EncodableValue("enabled"))));
        result->Success();
      } else if (method == "show") { Show(); result->Success();
      } else if (method == "hide") { ShowWindow(window_, SW_HIDE); result->Success();
      } else if (method == "exit") {
        quit_ = true; result->Success(); PostMessageW(window_, WM_CLOSE, 0, 0);
      } else if (method == "notificationSettings") {
        ShellExecuteW(window_, L"open", L"ms-settings:notifications", nullptr, nullptr, SW_SHOWNORMAL);
        result->Success();
      } else { result->NotImplemented(); }
    } catch (const winrt::hresult_error& e) {
      // Only HRESULTs are returned; no user task text or XML in diagnostics.
      std::fprintf(stderr, "XingJi native: %s HRESULT=0x%08lX\n", diagnostic_stage_.c_str(), static_cast<unsigned long>(e.code().value));
      result->Error("windows", "Windows integration failed: " + diagnostic_stage_, EncodableValue(static_cast<int32_t>(e.code().value)));
    } catch (...) { result->Error("windows", "Windows integration failed"); }
  });
}

void DesktopBridge::RegisterShell() {
  diagnostic_stage_ = "setAppId";
  winrt::check_hresult(SetCurrentProcessExplicitAppUserModelID(kAppId));
  const auto executable = Executable();
  diagnostic_stage_ = "registerProtocol";
  SetRegistryString(HKEY_CURRENT_USER, L"Software\\Classes\\xingji", nullptr, L"URL:XingJi");
  SetRegistryString(HKEY_CURRENT_USER, L"Software\\Classes\\xingji", L"URL Protocol", L"");
  SetRegistryString(HKEY_CURRENT_USER, L"Software\\Classes\\xingji\\shell\\open\\command", nullptr,
    L"\"" + executable + L"\" \"%1\"");
  SetRegistryString(HKEY_CURRENT_USER, L"Software\\Classes\\AppUserModelId\\XingJi.Desktop", L"DisplayName", L"星记");
  SetRegistryString(HKEY_CURRENT_USER, L"Software\\Classes\\AppUserModelId\\XingJi.Desktop", L"IconUri", executable);
  SetRegistryString(HKEY_CURRENT_USER, L"Software\\Classes\\AppUserModelId\\XingJi.Desktop", L"CustomActivator", kToastClsid);
  PWSTR programs = nullptr;
  diagnostic_stage_ = "startMenuFolder";
  winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs));
  const auto shortcut = std::filesystem::path(programs) / L"星记.lnk";
  CoTaskMemFree(programs);
  auto link = winrt::create_instance<IShellLinkW>(CLSID_ShellLink);
  bool valid_shortcut = false;
  if (SUCCEEDED(link.as<IPersistFile>()->Load(shortcut.c_str(), STGM_READ))) {
    wchar_t target[32768]{};
    if (SUCCEEDED(link->GetPath(target, 32768, nullptr, SLGP_RAWPATH)) && _wcsicmp(target, executable.c_str()) == 0) {
      PROPVARIANT app_id{}, activator{};
      auto existing_properties = link.as<IPropertyStore>();
      CLSID expected{};
      CLSIDFromString(kToastClsid, &expected);
      valid_shortcut = SUCCEEDED(existing_properties->GetValue(PKEY_AppUserModel_ID, &app_id)) && app_id.vt == VT_LPWSTR && wcscmp(app_id.pwszVal, kAppId) == 0 && SUCCEEDED(existing_properties->GetValue(PKEY_AppUserModel_ToastActivatorCLSID, &activator)) && activator.vt == VT_CLSID && IsEqualGUID(*activator.puuid, expected);
      PropVariantClear(&app_id); PropVariantClear(&activator);
    }
  }
  if (!valid_shortcut) {
  // The existing shortcut was opened STGM_READ for validation. Its property
  // store remains read-only; rebuild a fresh link before writing properties.
  link = winrt::create_instance<IShellLinkW>(CLSID_ShellLink);
  diagnostic_stage_ = "shortcutProperties";
  winrt::check_hresult(link->SetPath(executable.c_str()));
  winrt::check_hresult(link->SetWorkingDirectory(std::filesystem::path(executable).parent_path().c_str()));
  winrt::check_hresult(link->SetIconLocation(executable.c_str(), 0));
  auto properties = link.as<IPropertyStore>();
  PROPVARIANT value;
  winrt::check_hresult(InitPropVariantFromString(kAppId, &value));
  const HRESULT propertyResult = properties->SetValue(PKEY_AppUserModel_ID, value);
  PropVariantClear(&value);
  winrt::check_hresult(propertyResult);
  CLSID toast_clsid;
  winrt::check_hresult(CLSIDFromString(kToastClsid, &toast_clsid));
  winrt::check_hresult(InitPropVariantFromCLSID(toast_clsid, &value));
  const HRESULT clsid_result = properties->SetValue(PKEY_AppUserModel_ToastActivatorCLSID, value);
  PropVariantClear(&value);
  winrt::check_hresult(clsid_result);
  winrt::check_hresult(properties->Commit());
  diagnostic_stage_ = "saveShortcut";
  winrt::check_hresult(link.as<IPersistFile>()->Save(shortcut.c_str(), TRUE));
  }
  diagnostic_stage_ = "trayIcon";
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon); icon.hWnd = window_; icon.uID = 1;
  icon.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
  icon.uCallbackMessage = kTray;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"星记 · 私人加密备忘录");
  if (!Shell_NotifyIconW(tray_added_ ? NIM_MODIFY : NIM_ADD, &icon)) winrt::throw_last_error();
  tray_added_ = true;
  WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION);
}

void DesktopBridge::SetStartup(bool enabled) {
  const std::wstring key = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
  if (enabled) {
    SetRegistryString(HKEY_CURRENT_USER, key, L"XingJi", L"\"" + Executable() + L"\" --background");
  } else {
    HKEY run;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, KEY_SET_VALUE, &run) == ERROR_SUCCESS) {
      RegDeleteValueW(run, L"XingJi"); RegCloseKey(run);
    }
  }
}

void DesktopBridge::Emit(const std::string& event) { channel_->InvokeMethod("event", std::make_unique<EncodableValue>(event)); }
void DesktopBridge::Show() { ShowWindow(window_, SW_RESTORE); SetForegroundWindow(window_); }

std::optional<LRESULT> DesktopBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_CLIPBOARDUPDATE && clipboard_listening_) {
    channel_->InvokeMethod("clipboardImageChanged", std::make_unique<EncodableValue>(ClipboardHasImage()));
    return 0;
  }
  if (message == WM_CLOSE && ready_ && !quit_) { Emit("exit"); return 0; }
  if (message == WM_COPYDATA) {
    const auto* data = reinterpret_cast<COPYDATASTRUCT*>(lparam);
    if (data->dwData == 0x584A && data->cbData > 0 && data->cbData <= 8192) {
      const char* bytes = static_cast<const char*>(data->lpData);
      if (bytes[data->cbData - 1] == 0) { Show(); Emit(std::string(bytes, data->cbData - 1)); return 1; }
    }
  }
  if (message == WM_HOTKEY && wparam == kHotkey) { Show(); Emit("new"); return 0; }
  if (message == WM_WTSSESSION_CHANGE && wparam == WTS_SESSION_LOCK) Emit("lock");
  if (message == WM_POWERBROADCAST && (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND)) Emit("resume");
  if (message == kTray) {
    if (lparam == WM_LBUTTONUP) { Show(); Emit("show"); }
    if (lparam == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"打开星记");
      AppendMenuW(menu, MF_STRING, 2, L"快速新建  Ctrl+Shift+N");
      AppendMenuW(menu, MF_STRING, 3, L"锁定资料库");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, 4, L"退出星记");
      POINT cursor; GetCursorPos(&cursor); SetForegroundWindow(window_);
      const auto selected = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
        cursor.x, cursor.y, 0, window_, nullptr);
      DestroyMenu(menu);
      if (selected == 1) { Show(); Emit("show"); }
      if (selected == 2) { Show(); Emit("new"); }
      if (selected == 3) Emit("lock");
      if (selected == 4) Emit("exit");
    }
    return 0;
  }
  if (message == RegisterWindowMessageW(L"TaskbarCreated") && ready_) {
    tray_added_ = false;
    try { RegisterShell(); } catch (...) { Emit("shellError"); }
  }
  return std::nullopt;
}

DesktopBridge::~DesktopBridge() {
  if (clipboard_listening_) RemoveClipboardFormatListener(window_);
  UnregisterHotKey(window_, kHotkey);
  WTSUnRegisterSessionNotification(window_);
  RemovePropW(window_, instance_property.c_str());
  NOTIFYICONDATAW icon{}; icon.cbSize=sizeof(icon); icon.hWnd=window_; icon.uID=1;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  if (instance_mutex) { CloseHandle(instance_mutex); instance_mutex=nullptr; }
}
