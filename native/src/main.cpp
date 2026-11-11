#define NOMINMAX
#include <windows.h>
#include <wincodec.h>

#include <algorithm>
#include <cstdint>
#include <cctype>
#include <iomanip>
#include <limits>
#include <filesystem>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

struct Options {
  std::wstring input;
  std::wstring output;
  std::string format = "keep";
  UINT max_width = 0;
  UINT max_height = 0;
  int quality = 82;
};

template <typename T>
class ComPtr {
 public:
  ComPtr() = default;
  ~ComPtr() { reset(); }
  ComPtr(const ComPtr&) = delete;
  ComPtr& operator=(const ComPtr&) = delete;

  T** operator&() { return &ptr_; }
  T* operator->() const { return ptr_; }
  T* get() const { return ptr_; }
  operator bool() const { return ptr_ != nullptr; }

  void reset() {
    if (ptr_) {
      ptr_->Release();
      ptr_ = nullptr;
    }
  }

 private:
  T* ptr_ = nullptr;
};

class ComRuntime {
 public:
  ComRuntime() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    initialized_ = SUCCEEDED(hr);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
      throw std::runtime_error("Failed to initialize COM.");
    }
  }

  ~ComRuntime() {
    if (initialized_) {
      CoUninitialize();
    }
  }

 private:
  bool initialized_ = false;
};

void check(HRESULT hr, const std::string& message) {
  if (FAILED(hr)) {
    std::ostringstream stream;
    stream << message << " HRESULT=0x" << std::hex << static_cast<unsigned long>(hr);
    throw std::runtime_error(stream.str());
  }
}

std::wstring widen(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::string narrow(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  int size = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
  return result;
}

std::string json_escape(const std::string& value) {
  std::ostringstream out;
  for (char ch : value) {
    switch (ch) {
      case '"': out << "\\\""; break;
      case '\\': out << "\\\\"; break;
      case '\b': out << "\\b"; break;
      case '\f': out << "\\f"; break;
      case '\n': out << "\\n"; break;
      case '\r': out << "\\r"; break;
      case '\t': out << "\\t"; break;
      default:
        if (static_cast<unsigned char>(ch) < 0x20) {
          out << "\\u00" << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(static_cast<unsigned char>(ch)) << std::dec;
        } else {
          out << ch;
        }
    }
  }
  return out.str();
}

Options parse_args(int argc, char** argv) {
  Options options;
  std::map<std::string, std::string> args;
  for (int i = 1; i < argc; i += 2) {
    std::string key = argv[i];
    if (key.rfind("--", 0) != 0 || i + 1 >= argc) {
      throw std::runtime_error("Expected arguments in --key value form.");
    }
    key = key.substr(2);
    if (key != "input" && key != "output" && key != "format" && key != "quality" && key != "max-width" && key != "max-height") {
      throw std::runtime_error("Unknown option: --" + key);
    }
    if (args.count(key)) throw std::runtime_error("Duplicate option: --" + key);
    args[key] = argv[i + 1];
  }

  if (args.count("input")) options.input = widen(args["input"]);
  if (args.count("output")) options.output = widen(args["output"]);
  if (args.count("format")) options.format = args["format"];
  auto positive_integer = [](const std::string& text, unsigned long long maximum) {
    if (text.empty() || text.find_first_not_of("0123456789") != std::string::npos) {
      throw std::runtime_error("Expected a positive integer.");
    }
    auto value = std::stoull(text);
    if (!value || value > maximum) throw std::runtime_error("Integer option is out of range.");
    return value;
  };
  if (args.count("max-width")) options.max_width = static_cast<UINT>(positive_integer(args["max-width"], std::numeric_limits<UINT>::max()));
  if (args.count("max-height")) options.max_height = static_cast<UINT>(positive_integer(args["max-height"], std::numeric_limits<UINT>::max()));
  if (args.count("quality")) options.quality = static_cast<int>(positive_integer(args["quality"], 100));

  if (options.input.empty() || options.output.empty()) {
    throw std::runtime_error("--input and --output are required.");
  }
  if (options.format.empty()) {
    options.format = "keep";
  }
  std::transform(options.format.begin(), options.format.end(), options.format.begin(), [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
  return options;
}

GUID container_for_format(const Options& options, const GUID& source_container) {
  const std::string& format = options.format;
  if (format == "keep") return source_container;

  if (format == "jpeg" || format == "jpg") return GUID_ContainerFormatJpeg;
  if (format == "png") return GUID_ContainerFormatPng;
  if (format == "bmp") return GUID_ContainerFormatBmp;
  if (format == "tiff" || format == "tif") return GUID_ContainerFormatTiff;
  throw std::runtime_error("Unsupported output format: " + options.format);
}

std::string format_name_for_container(const GUID& container) {
  if (IsEqualGUID(container, GUID_ContainerFormatJpeg)) return "jpeg";
  if (IsEqualGUID(container, GUID_ContainerFormatPng)) return "png";
  if (IsEqualGUID(container, GUID_ContainerFormatBmp)) return "bmp";
  if (IsEqualGUID(container, GUID_ContainerFormatTiff)) return "tiff";
  return "unknown";
}

void compute_target_size(UINT width, UINT height, const Options& options, UINT& target_width, UINT& target_height) {
  double scale = 1.0;
  if (options.max_width > 0 && width > options.max_width) {
    scale = std::min(scale, static_cast<double>(options.max_width) / width);
  }
  if (options.max_height > 0 && height > options.max_height) {
    scale = std::min(scale, static_cast<double>(options.max_height) / height);
  }

  target_width = std::max<UINT>(1, static_cast<UINT>(width * scale));
  target_height = std::max<UINT>(1, static_cast<UINT>(height * scale));
}

void set_quality(IPropertyBag2* bag, const GUID& container, int quality) {
  if (!bag || (!IsEqualGUID(container, GUID_ContainerFormatJpeg) && !IsEqualGUID(container, GUID_ContainerFormatTiff))) {
    return;
  }

  PROPBAG2 option = {};
  option.pstrName = const_cast<LPOLESTR>(IsEqualGUID(container, GUID_ContainerFormatTiff) ? L"CompressionQuality" : L"ImageQuality");

  VARIANT value;
  VariantInit(&value);
  value.vt = VT_R4;
  value.fltVal = static_cast<float>(quality) / 100.0f;
  HRESULT hr = bag->Write(1, &option, &value);
  VariantClear(&value);
  check(hr, "Failed to set encoder quality.");
}

// Delete a newly created output on errors, after COM streams have released it.
struct OutputCleanup {
  fs::path path;
  bool committed = false;
  ~OutputCleanup() {
    if (!committed) {
      std::error_code ignored;
      fs::remove(path, ignored);
    }
  }
};

int run(const Options& options) {
  if (fs::exists(options.output)) {
    throw std::runtime_error("Output already exists; choose a new file to avoid overwriting data.");
  }
  OutputCleanup cleanup{fs::path(options.output)};
  ComRuntime com;

  ComPtr<IWICImagingFactory> factory;
  check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)), "Failed to create WIC factory.");

  ComPtr<IWICBitmapDecoder> decoder;
  check(factory->CreateDecoderFromFilename(options.input.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder), "Failed to open input image.");

  GUID source_container;
  check(decoder->GetContainerFormat(&source_container), "Failed to read input format.");
  if (!IsEqualGUID(source_container, GUID_ContainerFormatJpeg) && !IsEqualGUID(source_container, GUID_ContainerFormatPng) &&
      !IsEqualGUID(source_container, GUID_ContainerFormatBmp) && !IsEqualGUID(source_container, GUID_ContainerFormatTiff)) {
    throw std::runtime_error("Unsupported input format. Use JPEG, PNG, BMP, or TIFF.");
  }

  ComPtr<IWICBitmapFrameDecode> source_frame;
  check(decoder->GetFrame(0, &source_frame), "Failed to decode first image frame.");

  UINT original_width = 0;
  UINT original_height = 0;
  check(source_frame->GetSize(&original_width, &original_height), "Failed to read image size.");

  if (!original_width || !original_height || static_cast<std::uint64_t>(original_width) * original_height > 100000000ULL) {
    throw std::runtime_error("Input must have between 1 and 100 million pixels.");
  }

  UINT target_width = original_width;
  UINT target_height = original_height;
  compute_target_size(original_width, original_height, options, target_width, target_height);

  ComPtr<IWICBitmapSource> bitmap_source;
  if (target_width != original_width || target_height != original_height) {
    ComPtr<IWICBitmapScaler> scaler;
    check(factory->CreateBitmapScaler(&scaler), "Failed to create image scaler.");
    check(scaler->Initialize(source_frame.get(), target_width, target_height, WICBitmapInterpolationModeFant), "Failed to resize image.");
    check(scaler->QueryInterface(IID_PPV_ARGS(&bitmap_source)), "Failed to use resized bitmap.");
  } else {
    check(source_frame->QueryInterface(IID_PPV_ARGS(&bitmap_source)), "Failed to use source bitmap.");
  }

  GUID container = container_for_format(options, source_container);
  WICPixelFormatGUID target_pixel_format = IsEqualGUID(container, GUID_ContainerFormatJpeg) ? GUID_WICPixelFormat24bppBGR : GUID_WICPixelFormat32bppBGRA;

  ComPtr<IWICStream> stream;
  check(factory->CreateStream(&stream), "Failed to create output stream.");
  check(stream->InitializeFromFilename(options.output.c_str(), GENERIC_WRITE), "Failed to open output image.");

  ComPtr<IWICBitmapEncoder> encoder;
  check(factory->CreateEncoder(container, nullptr, &encoder), "Failed to create encoder.");
  check(encoder->Initialize(stream.get(), WICBitmapEncoderNoCache), "Failed to initialize encoder.");

  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  check(encoder->CreateNewFrame(&frame, &properties), "Failed to create output frame.");
  set_quality(properties.get(), container, options.quality);
  check(frame->Initialize(properties.get()), "Failed to initialize output frame.");
  check(frame->SetSize(target_width, target_height), "Failed to set output size.");
  check(frame->SetPixelFormat(&target_pixel_format), "Failed to set output pixel format.");
  ComPtr<IWICFormatConverter> converter;
  check(factory->CreateFormatConverter(&converter), "Failed to create pixel format converter.");
  check(converter->Initialize(bitmap_source.get(), target_pixel_format, WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom), "Failed to convert pixel format.");

  check(frame->WriteSource(converter.get(), nullptr), "Failed to write output image.");
  check(frame->Commit(), "Failed to commit output frame.");
  check(encoder->Commit(), "Failed to commit output image.");

  frame.reset();
  encoder.reset();
  stream.reset();

  std::uintmax_t input_size = fs::file_size(options.input);
  std::uintmax_t output_size = fs::file_size(options.output);
  double savings = input_size == 0 ? 0.0 : (1.0 - static_cast<double>(output_size) / static_cast<double>(input_size)) * 100.0;

  std::cout
      << "{"
      << "\"input\":\"" << json_escape(narrow(options.input)) << "\","
      << "\"output\":\"" << json_escape(narrow(options.output)) << "\","
      << "\"format\":\"" << format_name_for_container(container) << "\","
      << "\"original_width\":" << original_width << ","
      << "\"original_height\":" << original_height << ","
      << "\"width\":" << target_width << ","
      << "\"height\":" << target_height << ","
      << "\"input_size\":" << input_size << ","
      << "\"output_size\":" << output_size << ","
      << "\"savings_percent\":" << savings
      << "}"
      << std::endl;

  cleanup.committed = true;
  return 0;
}

int wmain(int argc, wchar_t** argv) {
  try {
    // Windows passes UTF-16 paths; convert explicitly rather than using the ANSI code page.
    std::vector<std::string> arguments;
    for (int i = 0; i < argc; ++i) arguments.push_back(narrow(argv[i]));
    std::vector<char*> pointers;
    for (auto& argument : arguments) pointers.push_back(argument.data());
    return run(parse_args(argc, pointers.data()));
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
