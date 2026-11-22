import Foundation

/// Errors reported by ``UnitConverter`` (returned to the model as readable text, never thrown out of a tool).
enum UnitConversionError: Error, LocalizedError, Equatable {
  case unknownUnit(String)
  case incompatible(from: String, to: String)
  case notFinite

  var errorDescription: String? {
    switch self {
    case .unknownUnit(let raw):
      return "Unknown unit '\(raw)'."
    case .incompatible(let from, let to):
      return "Cannot convert \(from) to \(to) (different physical dimensions)."
    case .notFinite:
      return "Value must be a finite number."
    }
  }
}

/// Pure, offline unit and measurement converter. Supports length, mass, temperature, volume,
/// area, speed, time, data size, data rate, energy, power, pressure, and angle.
enum UnitConverter {
  struct ConversionResult: Equatable, Sendable {
    var inputValue: Double
    var outputValue: Double
    var formatted: String
    var fromSymbol: String
    var toSymbol: String
    var category: String
  }

  private enum Category: String {
    case length, mass, temperature, volume, area, speed, time
    case dataSize = "data size"
    case dataRate = "data rate"
    case energy, power, pressure, angle
  }

  private struct UnitSpec {
    var category: Category
    var symbol: String
    /// Linear factor to the category's base unit (ignored for temperature).
    var toBase: Double
  }

  static func convert(value: Double, from rawFrom: String, to rawTo: String) throws -> ConversionResult {
    guard value.isFinite else { throw UnitConversionError.notFinite }
    guard let fromSpec = resolve(rawFrom) else { throw UnitConversionError.unknownUnit(rawFrom) }
    guard let toSpec = resolve(rawTo) else { throw UnitConversionError.unknownUnit(rawTo) }
    guard fromSpec.category == toSpec.category else {
      throw UnitConversionError.incompatible(from: fromSpec.symbol, to: toSpec.symbol)
    }

    let rawResult: Double
    if fromSpec.category == .temperature {
      rawResult = convertTemperature(value, from: fromSpec.symbol, to: toSpec.symbol)
    } else {
      rawResult = value * fromSpec.toBase / toSpec.toBase
    }
    guard rawResult.isFinite else { throw UnitConversionError.notFinite }
    let rounded = Double(String(format: "%.10g", rawResult)) ?? rawResult
    let normalized = rounded == 0 ? 0 : rounded
    let formatted = formatNumber(normalized)
    return ConversionResult(
      inputValue: value, outputValue: normalized, formatted: "\(formatted) \(toSpec.symbol)",
      fromSymbol: fromSpec.symbol, toSymbol: toSpec.symbol, category: fromSpec.category.rawValue)
  }

  private static func convertTemperature(_ value: Double, from: String, to: String) -> Double {
    let celsius: Double
    switch from {
    case "°C": celsius = value
    case "°F": celsius = (value - 32.0) * 5.0 / 9.0
    case "K": celsius = value - 273.15
    default: celsius = value
    }
    switch to {
    case "°C": return celsius
    case "°F": return celsius * 9.0 / 5.0 + 32.0
    case "K": return celsius + 273.15
    default: return celsius
    }
  }

  private static func formatNumber(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e12 {
      return String(format: "%.0f", value)
    }
    return String(format: "%.10g", value)
  }

  private static func normalize(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "°", with: "deg")
      .replacingOccurrences(of: "²", with: "2")
      .replacingOccurrences(of: "³", with: "3")
      .replacingOccurrences(of: "µ", with: "u")
      .replacingOccurrences(of: "μ", with: "u")
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .components(separatedBy: .whitespaces)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func resolve(_ raw: String) -> UnitSpec? {
    let key = normalize(raw)
    if let direct = unitTable[key] { return direct }
    // Handle compact forms like "floz" or "kmh".
    let compact = key.replacingOccurrences(of: " ", with: "")
    return unitTable[compact]
  }

  private static let unitTable: [String: UnitSpec] = {
    var map: [String: UnitSpec] = [:]
    func add(_ aliases: [String], _ category: Category, _ symbol: String, _ toBase: Double) {
      let spec = UnitSpec(category: category, symbol: symbol, toBase: toBase)
      for alias in aliases { map[alias] = spec }
    }

    // Length (base: meter)
    add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], .length, "mm", 0.001)
    add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], .length, "cm", 0.01)
    add(["m", "meter", "meters", "metre", "metres"], .length, "m", 1.0)
    add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], .length, "km", 1_000.0)
    add(["in", "inch", "inches"], .length, "in", 0.0254)
    add(["ft", "foot", "feet"], .length, "ft", 0.3048)
    add(["yd", "yard", "yards"], .length, "yd", 0.9144)
    add(["mi", "mile", "miles"], .length, "mi", 1_609.344)
    add(["nmi", "nautical mile", "nautical miles"], .length, "nmi", 1_852.0)

    // Mass (base: kilogram)
    add(["ug", "mcg", "microgram", "micrograms"], .mass, "µg", 1e-9)
    add(["mg", "milligram", "milligrams"], .mass, "mg", 1e-6)
    add(["g", "gram", "grams", "gramme", "grammes"], .mass, "g", 0.001)
    add(["kg", "kilogram", "kilograms", "kilo", "kilos"], .mass, "kg", 1.0)
    add(["t", "tonne", "tonnes", "metric ton", "metric tons"], .mass, "t", 1_000.0)
    add(["oz", "ounce", "ounces"], .mass, "oz", 0.028349523125)
    add(["lb", "lbs", "pound", "pounds"], .mass, "lb", 0.45359237)
    add(["st", "stone", "stones"], .mass, "st", 6.35029318)
    add(["us ton", "short ton", "ton", "tons"], .mass, "ton", 907.18474)

    // Temperature
    add(["c", "degc", "deg c", "celsius", "centigrade"], .temperature, "°C", 1.0)
    add(["f", "degf", "deg f", "fahrenheit"], .temperature, "°F", 1.0)
    add(["k", "kelvin"], .temperature, "K", 1.0)

    // Volume (base: liter)
    add(["ml", "milliliter", "milliliters", "millilitre", "millilitres", "cc"], .volume, "mL", 0.001)
    add(["cl", "centiliter", "centilitre"], .volume, "cL", 0.01)
    add(["l", "liter", "liters", "litre", "litres"], .volume, "L", 1.0)
    add(["m3", "cubic meter", "cubic meters"], .volume, "m³", 1_000.0)
    add(["tsp", "teaspoon", "teaspoons"], .volume, "tsp", 0.00492892159375)
    add(["tbsp", "tablespoon", "tablespoons"], .volume, "tbsp", 0.01478676478125)
    add(["floz", "fl oz", "fluid ounce", "fluid ounces"], .volume, "fl oz", 0.0295735295625)
    add(["cup", "cups"], .volume, "cup", 0.2365882365)
    add(["pt", "pint", "pints"], .volume, "pt", 0.473176473)
    add(["qt", "quart", "quarts"], .volume, "qt", 0.946352946)
    add(["gal", "gallon", "gallons", "us gal", "us gallon"], .volume, "gal", 3.785411784)
    add(["uk gal", "imp gal", "imperial gallon"], .volume, "imp gal", 4.54609)

    // Area (base: square meter)
    add(["cm2", "sq cm", "sqcm", "square centimeter", "square centimeters"], .area, "cm²", 0.0001)
    add(["m2", "sq m", "sqm", "square meter", "square meters", "square metre", "square metres"], .area, "m²", 1.0)
    add(["km2", "sq km", "sqkm", "square kilometer", "square kilometers"], .area, "km²", 1_000_000.0)
    add(["in2", "sq in", "sqin", "square inch", "square inches"], .area, "in²", 0.00064516)
    add(["ft2", "sq ft", "sqft", "square foot", "square feet"], .area, "ft²", 0.09290304)
    add(["yd2", "sq yd", "sqyd", "square yard", "square yards"], .area, "yd²", 0.83612736)
    add(["mi2", "sq mi", "sqmi", "square mile", "square miles"], .area, "mi²", 2_589_988.110336)
    add(["acre", "acres"], .area, "acre", 4_046.8564224)
    add(["ha", "hectare", "hectares"], .area, "ha", 10_000.0)

    // Speed (base: m/s)
    add(["m/s", "mps", "meters per second", "metres per second"], .speed, "m/s", 1.0)
    add(["km/h", "kmh", "kph", "kilometers per hour", "kilometres per hour"], .speed, "km/h", 1.0 / 3.6)
    add(["mph", "mi/h", "miles per hour"], .speed, "mph", 0.44704)
    add(["kn", "kt", "kts", "knot", "knots"], .speed, "kn", 1_852.0 / 3_600.0)
    add(["ft/s", "fps", "feet per second"], .speed, "ft/s", 0.3048)

    // Time (base: second)
    add(["ms", "millisecond", "milliseconds"], .time, "ms", 0.001)
    add(["s", "sec", "secs", "second", "seconds"], .time, "s", 1.0)
    add(["min", "mins", "minute", "minutes"], .time, "min", 60.0)
    add(["h", "hr", "hrs", "hour", "hours"], .time, "h", 3_600.0)
    add(["d", "day", "days"], .time, "day", 86_400.0)
    add(["wk", "week", "weeks"], .time, "week", 604_800.0)
    add(["yr", "year", "years"], .time, "year", 31_557_600.0)

    // Data size (base: byte)
    add(["bit", "bits"], .dataSize, "bit", 0.125)
    add(["kbit", "kilobit", "kilobits"], .dataSize, "kbit", 125.0)
    add(["mbit", "megabit", "megabits"], .dataSize, "Mbit", 125_000.0)
    add(["gbit", "gigabit", "gigabits"], .dataSize, "Gbit", 125_000_000.0)
    add(["b", "byte", "bytes"], .dataSize, "B", 1.0)
    add(["kb", "kilobyte", "kilobytes"], .dataSize, "KB", 1_000.0)
    add(["mb", "megabyte", "megabytes"], .dataSize, "MB", 1_000_000.0)
    add(["gb", "gigabyte", "gigabytes"], .dataSize, "GB", 1_000_000_000.0)
    add(["tb", "terabyte", "terabytes"], .dataSize, "TB", 1_000_000_000_000.0)
    add(["kib", "kibibyte", "kibibytes"], .dataSize, "KiB", 1_024.0)
    add(["mib", "mebibyte", "mebibytes"], .dataSize, "MiB", 1_048_576.0)
    add(["gib", "gibibyte", "gibibytes"], .dataSize, "GiB", 1_073_741_824.0)
    add(["tib", "tebibyte", "tebibytes"], .dataSize, "TiB", 1_099_511_627_776.0)

    // Data rate (base: bits per second)
    add(["bps", "bit/s", "bits per second"], .dataRate, "bps", 1.0)
    add(["kbps", "kbit/s"], .dataRate, "Kbps", 1_000.0)
    add(["mbps", "mbit/s"], .dataRate, "Mbps", 1_000_000.0)
    add(["gbps", "gbit/s"], .dataRate, "Gbps", 1_000_000_000.0)
    add(["kb/s", "kbytes/s"], .dataRate, "KB/s", 8_000.0)
    add(["mb/s", "mbytes/s"], .dataRate, "MB/s", 8_000_000.0)
    add(["gb/s", "gbytes/s"], .dataRate, "GB/s", 8_000_000_000.0)

    // Energy (base: joule)
    add(["j", "joule", "joules"], .energy, "J", 1.0)
    add(["kj", "kilojoule", "kilojoules"], .energy, "kJ", 1_000.0)
    add(["cal", "calorie", "calories"], .energy, "cal", 4.184)
    add(["kcal", "kilocalorie", "kilocalories", "food calorie"], .energy, "kcal", 4_184.0)
    add(["wh", "watt hour", "watt hours"], .energy, "Wh", 3_600.0)
    add(["kwh", "kilowatt hour", "kilowatt hours"], .energy, "kWh", 3_600_000.0)
    add(["btu"], .energy, "BTU", 1_055.05585262)

    // Power (base: watt)
    add(["w", "watt", "watts"], .power, "W", 1.0)
    add(["kw", "kilowatt", "kilowatts"], .power, "kW", 1_000.0)
    add(["mw", "megawatt", "megawatts"], .power, "MW", 1_000_000.0)
    add(["hp", "horsepower"], .power, "hp", 745.69987158227)

    // Pressure (base: pascal)
    add(["pa", "pascal", "pascals"], .pressure, "Pa", 1.0)
    add(["kpa", "kilopascal", "kilopascals"], .pressure, "kPa", 1_000.0)
    add(["hpa", "mbar", "millibar"], .pressure, "hPa", 100.0)
    add(["bar"], .pressure, "bar", 100_000.0)
    add(["psi"], .pressure, "psi", 6_894.757293168)
    add(["atm", "atmosphere", "atmospheres"], .pressure, "atm", 101_325.0)
    add(["mmhg", "torr"], .pressure, "mmHg", 133.322387415)

    // Angle (base: radian)
    add(["rad", "radian", "radians"], .angle, "rad", 1.0)
    add(["deg", "degree", "degrees"], .angle, "°", .pi / 180.0)

    return map
  }()
}
