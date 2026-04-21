#include "system_proxy_cleanup.h"

#include <shlobj.h>
#include <windows.h>
#include <wininet.h>

#include <algorithm>
#include <charconv>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace {

constexpr wchar_t kInternetSettingsKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kSystemProxyMarkerFileName[] = L"system-proxy.json";

struct WindowsProxySettings {
  DWORD proxy_enable = 0;
  std::optional<std::wstring> proxy_server;
  std::optional<std::wstring> proxy_override;
  std::optional<std::wstring> auto_config_url;
};

struct SystemProxyMarker {
  WindowsProxySettings previous_settings;
  WindowsProxySettings managed_settings;
};

std::wstring Trim(std::wstring_view value) {
  size_t start = 0;
  while (start < value.size() &&
         iswspace(static_cast<wint_t>(value[start])) != 0) {
    ++start;
  }

  size_t end = value.size();
  while (end > start && iswspace(static_cast<wint_t>(value[end - 1])) != 0) {
    --end;
  }

  return std::wstring(value.substr(start, end - start));
}

std::optional<std::wstring> NormalizeProxyText(const std::wstring& value) {
  std::wstring trimmed = Trim(value);
  if (trimmed.empty()) {
    return std::nullopt;
  }
  return trimmed;
}

std::optional<std::wstring> ReadRegistryStringValue(HKEY key,
                                                    const wchar_t* value_name) {
  DWORD value_type = 0;
  DWORD byte_count = 0;
  const LSTATUS size_status =
      RegGetValueW(key, nullptr, value_name, RRF_RT_REG_SZ, &value_type,
                   nullptr, &byte_count);
  if (size_status != ERROR_SUCCESS || byte_count == 0) {
    return std::nullopt;
  }

  std::vector<wchar_t> buffer(byte_count / sizeof(wchar_t), L'\0');
  DWORD read_byte_count = byte_count;
  const LSTATUS read_status =
      RegGetValueW(key, nullptr, value_name, RRF_RT_REG_SZ, &value_type,
                   buffer.data(), &read_byte_count);
  if (read_status != ERROR_SUCCESS || read_byte_count < sizeof(wchar_t)) {
    return std::nullopt;
  }

  return NormalizeProxyText(std::wstring(buffer.data()));
}

bool WriteRegistryStringValue(HKEY key, const wchar_t* value_name,
                              const std::optional<std::wstring>& value) {
  if (!value.has_value()) {
    const LSTATUS delete_status = RegDeleteValueW(key, value_name);
    return delete_status == ERROR_SUCCESS || delete_status == ERROR_FILE_NOT_FOUND;
  }

  const std::wstring& text = *value;
  const DWORD byte_count =
      static_cast<DWORD>((text.size() + 1) * sizeof(wchar_t));
  return RegSetValueExW(key, value_name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(text.c_str()),
                        byte_count) == ERROR_SUCCESS;
}

bool ReadCurrentWindowsProxySettings(WindowsProxySettings* settings) {
  HKEY key = nullptr;
  const LSTATUS open_status =
      RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0,
                    KEY_QUERY_VALUE, &key);
  if (open_status != ERROR_SUCCESS) {
    return false;
  }

  DWORD proxy_enable = 0;
  DWORD value_type = 0;
  DWORD byte_count = sizeof(proxy_enable);
  const LSTATUS proxy_enable_status =
      RegGetValueW(key, nullptr, L"ProxyEnable", RRF_RT_REG_DWORD, &value_type,
                   &proxy_enable, &byte_count);
  settings->proxy_enable =
      proxy_enable_status == ERROR_SUCCESS ? proxy_enable : 0;
  settings->proxy_server = ReadRegistryStringValue(key, L"ProxyServer");
  settings->proxy_override = ReadRegistryStringValue(key, L"ProxyOverride");
  settings->auto_config_url = ReadRegistryStringValue(key, L"AutoConfigURL");

  RegCloseKey(key);
  return true;
}

bool RefreshWinInetProxySettings() {
  const BOOL settings_changed =
      InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  const BOOL refresh =
      InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return settings_changed != FALSE && refresh != FALSE;
}

bool ApplyWindowsProxySettings(const WindowsProxySettings& settings) {
  HKEY key = nullptr;
  const LSTATUS create_status =
      RegCreateKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr);
  if (create_status != ERROR_SUCCESS) {
    return false;
  }

  bool success = RegSetValueExW(
                     key, L"ProxyEnable", 0, REG_DWORD,
                     reinterpret_cast<const BYTE*>(&settings.proxy_enable),
                     sizeof(settings.proxy_enable)) == ERROR_SUCCESS;
  success = success &&
            WriteRegistryStringValue(key, L"ProxyServer", settings.proxy_server);
  success = success && WriteRegistryStringValue(key, L"ProxyOverride",
                                                settings.proxy_override);
  success = success && WriteRegistryStringValue(key, L"AutoConfigURL",
                                                settings.auto_config_url);

  RegCloseKey(key);
  if (!success) {
    return false;
  }

  return RefreshWinInetProxySettings();
}

std::wstring ToLower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t ch) {
                   return static_cast<wchar_t>(towlower(ch));
                 });
  return value;
}

std::wstring NormalizeProxyHost(std::wstring host) {
  const std::wstring normalized = ToLower(Trim(host));
  if (normalized == L"127.0.0.1" || normalized == L"localhost" ||
      normalized == L"::1" || normalized == L"0:0:0:0:0:0:0:1") {
    return L"loopback";
  }
  return normalized;
}

std::optional<std::wstring> TryParseProxyEndpointKey(std::wstring value) {
  std::optional<std::wstring> candidate = NormalizeProxyText(value);
  if (!candidate.has_value()) {
    return std::nullopt;
  }

  const size_t equals_index = candidate->find(L'=');
  if (equals_index != std::wstring::npos && equals_index + 1 < candidate->size()) {
    candidate = NormalizeProxyText(candidate->substr(equals_index + 1));
  }
  if (!candidate.has_value()) {
    return std::nullopt;
  }

  std::wstring url = *candidate;
  if (url.find(L"://") == std::wstring::npos) {
    url = L"http://" + url;
  }

  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  components.dwHostNameLength = static_cast<DWORD>(-1);
  components.dwSchemeLength = static_cast<DWORD>(-1);
  components.dwUrlPathLength = static_cast<DWORD>(-1);
  components.dwExtraInfoLength = static_cast<DWORD>(-1);
  if (InternetCrackUrlW(url.c_str(), 0, 0, &components) == FALSE ||
      components.dwHostNameLength == 0 ||
      components.nPort == INTERNET_INVALID_PORT_NUMBER) {
    return std::nullopt;
  }

  std::wstring host(components.lpszHostName, components.dwHostNameLength);
  return NormalizeProxyHost(host) + L":" + std::to_wstring(components.nPort);
}

std::set<std::wstring> ParseProxyEndpointKeys(
    const std::optional<std::wstring>& proxy_server) {
  std::set<std::wstring> endpoints;
  if (!proxy_server.has_value()) {
    return endpoints;
  }

  size_t start = 0;
  while (start <= proxy_server->size()) {
    const size_t separator = proxy_server->find(L';', start);
    const size_t end =
        separator == std::wstring::npos ? proxy_server->size() : separator;
    if (auto endpoint = TryParseProxyEndpointKey(
            proxy_server->substr(start, end - start));
        endpoint.has_value()) {
      endpoints.insert(*endpoint);
    }
    if (separator == std::wstring::npos) {
      break;
    }
    start = separator + 1;
  }

  return endpoints;
}

std::set<std::wstring> ParseBypassListKeys(
    const std::optional<std::wstring>& bypass_list) {
  std::set<std::wstring> entries;
  if (!bypass_list.has_value()) {
    return entries;
  }

  size_t start = 0;
  while (start <= bypass_list->size()) {
    const size_t separator = bypass_list->find(L';', start);
    const size_t end =
        separator == std::wstring::npos ? bypass_list->size() : separator;
    const std::optional<std::wstring> candidate =
        NormalizeProxyText(bypass_list->substr(start, end - start));
    if (candidate.has_value()) {
      entries.insert(ToLower(*candidate));
    }
    if (separator == std::wstring::npos) {
      break;
    }
    start = separator + 1;
  }

  return entries;
}

bool ProxyBypassListsMatch(const std::optional<std::wstring>& current_bypass,
                           const std::optional<std::wstring>& managed_bypass) {
  return ParseBypassListKeys(current_bypass) ==
         ParseBypassListKeys(managed_bypass);
}

bool ProxyServerTargetsManagedEndpoint(
    const std::optional<std::wstring>& current_proxy_server,
    const std::optional<std::wstring>& managed_proxy_server) {
  const std::set<std::wstring> current_endpoints =
      ParseProxyEndpointKeys(current_proxy_server);
  const std::set<std::wstring> managed_endpoints =
      ParseProxyEndpointKeys(managed_proxy_server);
  return !current_endpoints.empty() && current_endpoints == managed_endpoints;
}

bool ProxySettingsMatch(const WindowsProxySettings& left,
                        const WindowsProxySettings& right) {
  return left.proxy_enable == right.proxy_enable &&
         left.proxy_server == right.proxy_server &&
         ProxyBypassListsMatch(left.proxy_override, right.proxy_override) &&
         left.auto_config_url == right.auto_config_url;
}

bool CurrentProxyIsManagedBy(const WindowsProxySettings& current,
                             const WindowsProxySettings& managed) {
  if (ProxySettingsMatch(current, managed)) {
    return true;
  }
  if (current.proxy_enable != 1 || managed.proxy_enable != 1) {
    return false;
  }
  if (!ProxyBypassListsMatch(current.proxy_override, managed.proxy_override) ||
      current.auto_config_url != managed.auto_config_url) {
    return false;
  }
  return ProxyServerTargetsManagedEndpoint(current.proxy_server,
                                           managed.proxy_server);
}

size_t SkipJsonWhitespace(std::string_view json, size_t start) {
  while (start < json.size() &&
         std::isspace(static_cast<unsigned char>(json[start])) != 0) {
    ++start;
  }
  return start;
}

bool ExtractJsonObject(std::string_view json, const char* key,
                       std::string_view* object_view) {
  const std::string key_token = std::string("\"") + key + "\"";
  const size_t key_position = json.find(key_token);
  if (key_position == std::string_view::npos) {
    return false;
  }

  const size_t colon_position =
      json.find(':', key_position + key_token.size());
  if (colon_position == std::string_view::npos) {
    return false;
  }

  const size_t object_start = json.find('{', colon_position + 1);
  if (object_start == std::string_view::npos) {
    return false;
  }

  int depth = 0;
  bool in_string = false;
  bool escaped = false;
  for (size_t index = object_start; index < json.size(); ++index) {
    const char ch = json[index];
    if (in_string) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        in_string = false;
      }
      continue;
    }

    if (ch == '"') {
      in_string = true;
      continue;
    }
    if (ch == '{') {
      ++depth;
      continue;
    }
    if (ch == '}') {
      --depth;
      if (depth == 0) {
        *object_view = json.substr(object_start, index - object_start + 1);
        return true;
      }
    }
  }

  return false;
}

bool ParseJsonStringLiteral(std::string_view json, size_t start,
                            std::string* value, size_t* next_position) {
  if (start >= json.size() || json[start] != '"') {
    return false;
  }

  std::string parsed;
  parsed.reserve(json.size() - start);
  for (size_t index = start + 1; index < json.size(); ++index) {
    const char ch = json[index];
    if (ch == '"') {
      *value = parsed;
      *next_position = index + 1;
      return true;
    }
    if (ch != '\\') {
      parsed.push_back(ch);
      continue;
    }
    if (index + 1 >= json.size()) {
      return false;
    }

    const char escaped = json[++index];
    switch (escaped) {
      case '"':
      case '\\':
      case '/':
        parsed.push_back(escaped);
        break;
      case 'b':
        parsed.push_back('\b');
        break;
      case 'f':
        parsed.push_back('\f');
        break;
      case 'n':
        parsed.push_back('\n');
        break;
      case 'r':
        parsed.push_back('\r');
        break;
      case 't':
        parsed.push_back('\t');
        break;
      case 'u': {
        if (index + 4 >= json.size()) {
          return false;
        }
        bool hex_ok = true;
        uint32_t codepoint = 0;
        for (int offset = 1; offset <= 4; ++offset) {
          const char hex = json[index + offset];
          codepoint <<= 4;
          if (hex >= '0' && hex <= '9') {
            codepoint |= static_cast<uint32_t>(hex - '0');
          } else if (hex >= 'a' && hex <= 'f') {
            codepoint |= static_cast<uint32_t>(hex - 'a' + 10);
          } else if (hex >= 'A' && hex <= 'F') {
            codepoint |= static_cast<uint32_t>(hex - 'A' + 10);
          } else {
            hex_ok = false;
            break;
          }
        }
        if (!hex_ok || codepoint > 0x7F) {
          return false;
        }
        parsed.push_back(static_cast<char>(codepoint));
        index += 4;
        break;
      }
      default:
        return false;
    }
  }

  return false;
}

std::optional<std::wstring> Utf16FromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::nullopt;
  }

  const int length =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return std::nullopt;
  }

  std::wstring converted(static_cast<size_t>(length), L'\0');
  const int converted_length =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), converted.data(),
                          length);
  if (converted_length != length) {
    return std::nullopt;
  }

  return NormalizeProxyText(converted);
}

bool ExtractJsonOptionalString(std::string_view object_json, const char* key,
                               std::optional<std::wstring>* value) {
  const std::string key_token = std::string("\"") + key + "\"";
  const size_t key_position = object_json.find(key_token);
  if (key_position == std::string_view::npos) {
    return false;
  }

  const size_t colon_position =
      object_json.find(':', key_position + key_token.size());
  if (colon_position == std::string_view::npos) {
    return false;
  }

  const size_t value_position = SkipJsonWhitespace(object_json, colon_position + 1);
  if (value_position >= object_json.size()) {
    return false;
  }
  if (object_json.compare(value_position, 4, "null") == 0) {
    *value = std::nullopt;
    return true;
  }

  std::string utf8_value;
  size_t next_position = value_position;
  if (!ParseJsonStringLiteral(object_json, value_position, &utf8_value,
                              &next_position)) {
    return false;
  }

  *value = Utf16FromUtf8(utf8_value);
  return true;
}

bool ExtractJsonInt(std::string_view object_json, const char* key,
                    DWORD* value) {
  const std::string key_token = std::string("\"") + key + "\"";
  const size_t key_position = object_json.find(key_token);
  if (key_position == std::string_view::npos) {
    return false;
  }

  const size_t colon_position =
      object_json.find(':', key_position + key_token.size());
  if (colon_position == std::string_view::npos) {
    return false;
  }

  size_t value_position = SkipJsonWhitespace(object_json, colon_position + 1);
  if (value_position >= object_json.size()) {
    return false;
  }

  size_t end_position = value_position;
  while (end_position < object_json.size() &&
         std::isdigit(static_cast<unsigned char>(object_json[end_position])) !=
             0) {
    ++end_position;
  }
  if (end_position == value_position) {
    return false;
  }

  unsigned long parsed_value = 0;
  const std::string_view number_view =
      object_json.substr(value_position, end_position - value_position);
  const auto [parse_end, parse_error] =
      std::from_chars(number_view.data(),
                      number_view.data() + number_view.size(), parsed_value);
  if (parse_error != std::errc() ||
      parse_end != number_view.data() + number_view.size()) {
    return false;
  }
  *value = static_cast<DWORD>(parsed_value);
  return true;
}

bool ParseWindowsProxySettings(std::string_view object_json,
                               WindowsProxySettings* settings) {
  DWORD proxy_enable = 0;
  std::optional<std::wstring> proxy_server;
  std::optional<std::wstring> proxy_override;
  std::optional<std::wstring> auto_config_url;
  if (!ExtractJsonInt(object_json, "proxyEnable", &proxy_enable) ||
      !ExtractJsonOptionalString(object_json, "proxyServer", &proxy_server) ||
      !ExtractJsonOptionalString(object_json, "proxyOverride", &proxy_override) ||
      !ExtractJsonOptionalString(object_json, "autoConfigUrl",
                                 &auto_config_url)) {
    return false;
  }

  settings->proxy_enable = proxy_enable;
  settings->proxy_server = proxy_server;
  settings->proxy_override = proxy_override;
  settings->auto_config_url = auto_config_url;
  return true;
}

bool ReadSystemProxyMarker(const std::filesystem::path& marker_path,
                           SystemProxyMarker* marker) {
  std::ifstream input(marker_path, std::ios::binary);
  if (!input) {
    return false;
  }

  const std::string json((std::istreambuf_iterator<char>(input)),
                         std::istreambuf_iterator<char>());
  if (json.empty()) {
    return false;
  }

  std::string_view previous_object;
  std::string_view managed_object;
  if (!ExtractJsonObject(json, "previousSettings", &previous_object) ||
      !ExtractJsonObject(json, "managedSettings", &managed_object)) {
    return false;
  }

  return ParseWindowsProxySettings(previous_object,
                                   &marker->previous_settings) &&
         ParseWindowsProxySettings(managed_object, &marker->managed_settings);
}

std::vector<std::filesystem::path> FindSystemProxyMarkerPaths() {
  std::vector<std::filesystem::path> markers;
  PWSTR roaming_app_data = nullptr;
  if (SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                           &roaming_app_data) != S_OK ||
      roaming_app_data == nullptr) {
    return markers;
  }

  const std::filesystem::path app_data_root(roaming_app_data);
  CoTaskMemFree(roaming_app_data);

  std::set<std::wstring> unique_paths;
  const auto add_marker_if_present = [&](const std::filesystem::path& path) {
    std::error_code error;
    if (!std::filesystem::exists(path, error) || error) {
      return;
    }
    const std::wstring normalized = path.native();
    if (unique_paths.insert(normalized).second) {
      markers.push_back(path);
    }
  };

  add_marker_if_present(app_data_root / L"com.example" / L"gorion_clean" /
                        L"gorion" / L"runtime" / kSystemProxyMarkerFileName);
  add_marker_if_present(app_data_root / L"gorion_clean" / L"gorion" /
                        L"runtime" / kSystemProxyMarkerFileName);

  std::error_code company_error;
  for (const auto& company_entry :
       std::filesystem::directory_iterator(app_data_root, company_error)) {
    if (company_error) {
      break;
    }
    if (!company_entry.is_directory(company_error) || company_error) {
      continue;
    }

    add_marker_if_present(company_entry.path() / L"gorion" / L"runtime" /
                          kSystemProxyMarkerFileName);

    std::error_code product_error;
    for (const auto& product_entry :
         std::filesystem::directory_iterator(company_entry.path(),
                                             product_error)) {
      if (product_error) {
        break;
      }
      if (!product_entry.is_directory(product_error) || product_error) {
        continue;
      }

      add_marker_if_present(product_entry.path() / L"gorion" / L"runtime" /
                            kSystemProxyMarkerFileName);
    }
  }

  return markers;
}

void DeleteMarkerFile(const std::filesystem::path& marker_path) {
  std::error_code error;
  std::filesystem::remove(marker_path, error);
}

void CleanupMarkerIfOwned(const std::filesystem::path& marker_path) {
  SystemProxyMarker marker;
  if (!ReadSystemProxyMarker(marker_path, &marker)) {
    return;
  }

  WindowsProxySettings current;
  if (!ReadCurrentWindowsProxySettings(&current)) {
    return;
  }

  bool should_delete_marker = false;
  if (CurrentProxyIsManagedBy(current, marker.managed_settings)) {
    if (ApplyWindowsProxySettings(marker.previous_settings)) {
      should_delete_marker = true;
    }
  } else {
    should_delete_marker = true;
  }

  if (should_delete_marker) {
    DeleteMarkerFile(marker_path);
  }
}

}  // namespace

void RestoreManagedWindowsSystemProxyForSessionEnd() {
  for (const std::filesystem::path& marker_path : FindSystemProxyMarkerPaths()) {
    CleanupMarkerIfOwned(marker_path);
  }
}
