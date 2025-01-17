# frozen_string_literal: true

# Collection of methods for performing HVAC design load and autosizing calculations.
module HVACSizing
  # Calculates heating/cooling design loads, and selects equipment
  # values (e.g., capacities, airflows) specific to each HVAC system.
  # Calculations follow ACCA Manual J (and S).
  #
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hvac_systems [Array<Hash>] List of HPXML HVAC (heating and/or cooling) systems
  # @param update_hpxml [Boolean] Whether to update the HPXML object so that in.xml reports capacities/airflows
  # @param output_format [String] Detailed output file format ('csv', 'json', or 'msgpack')
  # @param output_file_path [String] Detailed output file path
  # @return [Hash] Map of HVAC systems => HVACSizingValues objects
  def self.calculate(runner, weather, hpxml_bldg, hvac_systems, update_hpxml: true,
                     output_format: 'csv', output_file_path: nil)

    check_for_errors(hpxml_bldg, hvac_systems)

    mj = MJValues.new
    process_site_calcs_and_design_temps(mj, weather, hpxml_bldg)

    # Calculate individual design load components
    all_zone_loads, all_space_loads = init_loads(hpxml_bldg)
    process_load_windows_skylights(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    process_load_doors(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    process_load_walls(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    process_load_roofs(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    process_load_ceilings(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    process_load_floors(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    process_load_slabs(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    process_load_infiltration_ventilation(mj, hpxml_bldg, all_zone_loads, all_space_loads, weather)
    process_load_internal_gains(hpxml_bldg, all_zone_loads, all_space_loads)

    # Calculate heating/cooling totals
    hpxml_bldg.conditioned_zones.each do |zone|
      aggregate_loads_to_totals(all_zone_loads[zone])
      zone.spaces.each do |space|
        aggregate_loads_to_totals(all_space_loads[space])
      end
    end

    # Assign initial loads for each HVAC system (before duct loads)
    all_hvac_loads = {}
    hvac_systems.each do |hvac_system|
      hvac_heating, hvac_cooling = hvac_system[:heating], hvac_system[:cooling]
      zone = hvac_heating.nil? ? hvac_cooling.zone : hvac_heating.zone
      next if is_system_to_skip(hvac_heating, hvac_cooling, zone)

      all_hvac_loads[hvac_system] = all_zone_loads[zone].dup
    end

    # Calculate final loads and capacities for each HVAC system
    @all_hvac_sizings = {}
    hvac_systems.each do |hvac_system|
      hvac_heating, hvac_cooling = hvac_system[:heating], hvac_system[:cooling]
      zone = hvac_heating.nil? ? hvac_cooling.zone : hvac_heating.zone
      next if is_system_to_skip(hvac_heating, hvac_cooling, zone)

      # Calculate fraction of zone load served by this HVAC system
      frac_zone_heat_load_served, frac_zone_cool_load_served = get_fractions_load_served(hvac_heating, hvac_cooling, hpxml_bldg, hvac_systems, zone)

      # Calculate system loads (zone load served by this system plus duct loads)
      hvac_loads = all_hvac_loads[hvac_system]
      apply_hvac_air_temperatures(mj, hvac_loads, hvac_heating, hvac_cooling)
      apply_fractions_load_served(hvac_heating, hvac_loads, frac_zone_heat_load_served, frac_zone_cool_load_served)
      apply_hvac_duct_loads_heating(mj, zone, hvac_loads, all_zone_loads[zone], all_space_loads, hvac_heating, hpxml_bldg)
      apply_hvac_duct_loads_cooling(mj, zone, hvac_loads, all_zone_loads[zone], all_space_loads, hvac_cooling, hpxml_bldg, weather)
      apply_hvac_cfis_loads(mj, hvac_loads, all_zone_loads[zone], hvac_heating, hvac_cooling, hpxml_bldg)
      apply_hvac_blower_heat_load(hvac_loads, all_zone_loads[zone], hvac_heating, hvac_cooling)
      apply_hvac_piping_load(hvac_loads, all_zone_loads[zone], hvac_heating)

      # Calculate HVAC equipment sizes
      hvac_sizings = HVACSizingValues.new
      apply_hvac_loads_to_hvac_sizings(hvac_sizings, hvac_loads)
      apply_hvac_heat_pump_logic(hvac_sizings, hvac_cooling, frac_zone_heat_load_served, frac_zone_cool_load_served, hpxml_bldg)
      apply_hvac_equipment_adjustments(mj, runner, hvac_sizings, weather, hvac_heating, hvac_cooling, hvac_system, hpxml_bldg)
      apply_hvac_installation_quality(mj, hvac_sizings, hvac_heating, hvac_cooling, frac_zone_heat_load_served, frac_zone_cool_load_served, hpxml_bldg)
      apply_hvac_autosizing_factors_and_limits(hvac_sizings, hvac_heating, hvac_cooling)
      apply_hvac_final_capacities(hvac_sizings, hvac_heating, hvac_cooling, hpxml_bldg)
      apply_hvac_final_airflows(hvac_sizings, hvac_heating, hvac_cooling)
      apply_hvac_ground_loop(mj, runner, hvac_sizings, weather, hvac_cooling, hpxml_bldg)
      @all_hvac_sizings[hvac_system] = hvac_sizings

      if update_hpxml
        # Assign capacities, airflows, etc. to HPXML systems
        assign_to_hpxml_system(hvac_heating, hvac_cooling, hvac_sizings)
      end
    end

    # Calculate building loads (sum of all zone loads)
    bldg_loads = aggregate_zone_loads_to_bldg(all_zone_loads)

    # Remove any automatically created spaces from output files
    auto_space = all_space_loads.keys.find { |space| space.id.start_with? Constants.AutomaticallyAdded }
    all_space_loads.delete(auto_space) if not auto_space.nil?

    # Assign design loads to HPXML objects for output
    if update_hpxml
      # HPXML Building
      assign_to_hpxml_obj(hpxml_bldg.hvac_plant, bldg_loads)

      # HPXML Zones
      all_zone_loads.each do |zone, zone_loads|
        next if zone.id.start_with? Constants.AutomaticallyAdded

        assign_to_hpxml_obj(zone, zone_loads)
      end

      # HPXML Spaces
      all_space_loads.each do |space, space_loads|
        assign_to_hpxml_obj(space, space_loads)
      end
    end

    # Write detailed outputs (useful for Form J1)
    if not output_file_path.nil?
      write_detailed_output(output_format, output_file_path, hpxml_bldg, all_zone_loads, all_space_loads)
    end

    return @all_hvac_sizings
  end

  # Checks whether we will be performing sizing calculations on the given HPXML HVAC system.
  #
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param zone [HPXML::Zone] The current zone of interest
  # @return [Boolean] true if this system should be excluded from sizing calculations
  def self.is_system_to_skip(hvac_heating, hvac_cooling, zone)
    # Skip systems not attached to this zone
    if (not hvac_heating.nil?) && (hvac_heating.zone != zone)
      return true
    end
    if (not hvac_cooling.nil?) && (hvac_cooling.zone != zone)
      return true
    end

    # Shared systems below should be converted to other equivalent
    # systems before being autosized.

    cooling_type = get_hvac_cooling_type(hvac_cooling)
    if [HPXML::HVACTypeChiller,
        HPXML::HVACTypeCoolingTower].include?(cooling_type)
      return true
    end

    heating_type = get_hvac_heating_type(hvac_heating)
    if (heating_type == HPXML::HVACTypeHeatPumpWaterLoopToAir) &&
       hvac_heating.fraction_heat_load_served.nil?
      return true
    end

    return false
  end

  # Initial checks for errors (i.e., situations that should not occur). Throws an error if found.
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hvac_systems [Array<Hash>] List of HPXML HVAC (heating and/or cooling) systems
  # @return [void]
  def self.check_for_errors(hpxml_bldg, hvac_systems)
    # Check all surfaces adjacent to conditioned space (and not adiabatic) are
    # not attached to spaces of unconditioned zones.
    hpxml_bldg.surfaces.each do |surface|
      next unless HPXML::conditioned_locations_this_unit.include?(surface.interior_adjacent_to)
      next if surface.exterior_adjacent_to == HPXML::LocationOtherHousingUnit

      if surface.space.zone.zone_type != HPXML::ZoneTypeConditioned
        fail "Surface '#{surface.id}' is attached to the space of an unconditioned zone."
      end
    end

    # Check all HVAC systems are not attached to unconditioned zones.
    hvac_systems.each do |hvac_system|
      hvac_heating, hvac_cooling = hvac_system[:heating], hvac_system[:cooling]
      zone = hvac_heating.nil? ? hvac_cooling.zone : hvac_heating.zone
      next if is_system_to_skip(hvac_heating, hvac_cooling, zone)

      if (not hvac_heating.nil?) && (hvac_heating.zone.zone_type != HPXML::ZoneTypeConditioned)
        fail "HVAC system '#{hvac_heating.id}' is attached to an unconditioned zone."
      end
      if (not hvac_cooling.nil?) && (hvac_cooling.zone.zone_type != HPXML::ZoneTypeConditioned)
        fail "HVAC system '#{hvac_cooling.id}' is attached to an unconditioned zone."
      end
    end
  end

  # Assigns site values and design temperatures to the mj object.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.process_site_calcs_and_design_temps(mj, weather, hpxml_bldg)
    # CLTD adjustments based on daily temperature range
    mj.daily_range_temp_adjust = [4, 0, -5]

    # Manual J indoor conditions
    mj.cool_setpoint = hpxml_bldg.header.manualj_cooling_setpoint
    mj.heat_setpoint = hpxml_bldg.header.manualj_heating_setpoint

    # Calculate the design temperature differences
    mj.ctd = [hpxml_bldg.header.manualj_cooling_design_temp - mj.cool_setpoint, 0.0].max
    mj.htd = [mj.heat_setpoint - hpxml_bldg.header.manualj_heating_design_temp, 0.0].max

    # Determine class (low, medium, high) based on average Daily Temperature Range (DTR)
    mj.daily_range_num = { HPXML::ManualJDailyTempRangeLow => 0,
                           HPXML::ManualJDailyTempRangeMedium => 1,
                           HPXML::ManualJDailyTempRangeHigh => 2 }[hpxml_bldg.header.manualj_daily_temp_range]

    # Altitude Correction Factors (ACF) taken from Table 10A (sea level - 12,000 ft)
    acfs = [1.0, 0.97, 0.93, 0.89, 0.87, 0.84, 0.80, 0.77, 0.75, 0.72, 0.69, 0.66, 0.63]

    # Calculate the altitude correction factor (ACF) for the site
    alt_cnt = (hpxml_bldg.elevation / 1000.0).to_i
    mj.acf = MathTools.interp2(hpxml_bldg.elevation, alt_cnt * 1000.0, (alt_cnt + 1.0) * 1000.0, acfs[alt_cnt], acfs[alt_cnt + 1])

    mj.p_psi = Psychrometrics.Pstd_fZ(hpxml_bldg.elevation)
    mj.p_atm = UnitConversions.convert(mj.p_psi, 'psi', 'atm')

    # Calculate interior/outdoor wetbulb temperature for cooling
    mj.cool_indoor_wetbulb = Psychrometrics.Twb_fT_R_P(nil, mj.cool_setpoint, hpxml_bldg.header.manualj_humidity_setpoint, mj.p_psi)
    mj.cool_outdoor_wetbulb = Psychrometrics.Twb_fT_w_P(nil, hpxml_bldg.header.manualj_cooling_design_temp, weather.design.CoolingHumidityRatio, mj.p_psi)

    # Design Grains (DG), difference between absolute humidity of the outdoor air and outdoor humidity of the indoor air
    mj.cool_design_grains = hpxml_bldg.header.manualj_humidity_difference

    # Calculate indoor enthalpy in Btu/lb for cooling
    hr_indoor_cooling = Psychrometrics.w_fT_R_P(mj.cool_setpoint, hpxml_bldg.header.manualj_humidity_setpoint, mj.p_psi)
    mj.cool_indoor_enthalpy = Psychrometrics.h_fT_w(mj.cool_setpoint, hr_indoor_cooling)

    # Indoor air density
    avg_setpoint = (mj.cool_setpoint + mj.heat_setpoint) / 2.0
    mj.indoor_air_density = UnitConversions.convert(mj.p_atm, 'atm', 'Btu/ft^3') / (Gas.Air.r * UnitConversions.convert(avg_setpoint, 'F', 'R'))
    mj.outside_air_density = UnitConversions.convert(mj.p_atm, 'atm', 'Btu/ft^3') / (Gas.Air.r * UnitConversions.convert(weather.data.AnnualAvgDrybulb, 'F', 'R'))

    # Other
    if (not hpxml_bldg.site.soil_type.nil?) && (not hpxml_bldg.site.moisture_type.nil?)
      if ([HPXML::SiteSoilTypeClay,
           HPXML::SiteSoilTypeUnknown].include?(hpxml_bldg.site.soil_type) &&
          [HPXML::SiteSoilMoistureTypeWet,
           HPXML::SiteSoilMoistureTypeMixed].include?(hpxml_bldg.site.moisture_type))
        # Heavy moist soil, R-value/ft=1.25 (Manual J default for Table 4A)
        mj.ground_conductivity = 1.0 / 1.25
      elsif ([HPXML::SiteSoilTypeSand,
              HPXML::SiteSoilTypeGravel,
              HPXML::SiteSoilTypeSilt].include?(hpxml_bldg.site.soil_type) &&
             [HPXML::SiteSoilMoistureTypeDry].include?(hpxml_bldg.site.moisture_type))
        # Light dry soil, R-value/ft=5.0
        mj.ground_conductivity = 1.0 / 5.0
      else
        # Heavy dry or light moist soil, R-value/ft=2.0
        mj.ground_conductivity = 1.0 / 2.0
      end
    else
      mj.ground_conductivity = hpxml_bldg.site.ground_conductivity
    end

    # Design Temperatures

    mj.cool_design_temps = {}
    mj.heat_design_temps = {}

    locations = []
    hpxml_bldg.surfaces.each do |surface|
      locations << surface.interior_adjacent_to
      locations << surface.exterior_adjacent_to
    end
    hpxml_bldg.hvac_distributions.each do |hvac_dist|
      hvac_dist.ducts.each do |duct|
        locations << duct.duct_location
      end
    end

    locations.uniq.each do |location|
      next if [HPXML::LocationGround].include? location

      if [HPXML::LocationOutside, HPXML::LocationRoofDeck, HPXML::LocationManufacturedHomeUnderBelly].include? location
        mj.cool_design_temps[location] = hpxml_bldg.header.manualj_cooling_design_temp
        mj.heat_design_temps[location] = hpxml_bldg.header.manualj_heating_design_temp
      elsif HPXML::conditioned_locations.include? location
        mj.cool_design_temps[location] = get_design_temp_cooling(mj, weather, HPXML::LocationConditionedSpace, hpxml_bldg)
        mj.heat_design_temps[location] = get_design_temp_heating(mj, weather, HPXML::LocationConditionedSpace, hpxml_bldg)
      else
        mj.cool_design_temps[location] = get_design_temp_cooling(mj, weather, location, hpxml_bldg)
        mj.heat_design_temps[location] = get_design_temp_heating(mj, weather, location, hpxml_bldg)
      end
    end
  end

  # Calculates the MJ Design Grains.
  #
  # Design Grains (DG) values equal the difference between the humidity ratio of the outdoor
  # air and the humidity ratio of the indoor air. They are used to estimate the latent
  # infiltration/ventilation loads for the cooling season.
  #
  # @param hr_outdoor_cooling [Double] Outdoor humidity ratio during cooling (lb/lb)
  # @param hr_indoor_cooling [Double] Indoor humidity ratio during cooling (lb/lb)
  # @return [Double] Indoor-outdoor humidity ratio difference (grains)
  def self.calculate_design_grains(hr_outdoor_cooling, hr_indoor_cooling)
    cool_outdoor_grains = UnitConversions.convert(hr_outdoor_cooling, 'lbm/lbm', 'grains')
    cool_indoor_grains = UnitConversions.convert(hr_indoor_cooling, 'lbm/lbm', 'grains')
    cool_design_grains = cool_outdoor_grains - cool_indoor_grains
    return cool_design_grains
  end

  # Calculates Daily Range category.
  #
  # Daily range values equal the average difference between the daily high and low drybulb
  # temperatures at a particular location. Large daily range values characterize air climates
  # and high altitude climates. Small values are associated with locations near a large body
  # of water.
  #
  # DRs are reduced to three categories:
  # - Low (swing less than 16 F)
  # - Medium (swing between 16 F and 25 F)
  # - High (swing exceeds 25 F)
  #
  # @param daily_temperature_range [Double] Daily temperature range (delta F)
  # @return [String] DR category
  def self.determine_daily_temperature_range_class(daily_temperature_range)
    if daily_temperature_range < 16.0
      return HPXML::ManualJDailyTempRangeLow
    elsif daily_temperature_range > 25.0
      return HPXML::ManualJDailyTempRangeHigh
    else
      return HPXML::ManualJDailyTempRangeMedium
    end
  end

  # Determines the heating design temperature for the given location (space type).
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param location [String] The location of interest (HPXML::LocationXXX)
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Double] Heating design temperature (F)
  def self.get_design_temp_heating(mj, weather, location, hpxml_bldg)
    outdoor_design_temp = hpxml_bldg.header.manualj_heating_design_temp
    ground_temp = weather.data.ShallowGroundMonthlyTemps.min

    if location == HPXML::LocationConditionedSpace
      heat_temp = mj.heat_setpoint

    elsif (location == HPXML::LocationAtticUnvented) || (location == HPXML::LocationAtticVented)

      attic_floors = hpxml_bldg.floors.select { |f| f.is_ceiling && [f.interior_adjacent_to, f.exterior_adjacent_to].include?(location) }
      avg_floor_rvalue = calculate_average_r_value(attic_floors)

      attic_roofs = hpxml_bldg.roofs.select { |r| r.interior_adjacent_to == location }
      avg_roof_rvalue = calculate_average_r_value(attic_roofs)

      if avg_floor_rvalue < avg_roof_rvalue
        # Attic is considered to be encapsulated. MJ8 says to use an attic
        # temperature of 95F, however alternative approaches are permissible
        if location == HPXML::LocationAtticVented
          heat_temp = outdoor_design_temp
        else
          heat_temp = calculate_space_design_temp(mj, location, weather, hpxml_bldg, mj.heat_setpoint, outdoor_design_temp, ground_temp, false)
        end
      else
        heat_temp = outdoor_design_temp
      end

    elsif location == HPXML::LocationGarage && hpxml_bldg.foundation_walls.count { |fw| fw.interior_adjacent_to == HPXML::LocationGarage } == 0
      # Completely above-grade garage
      # Calculate the garage heating design temperature based on Table 4C for closed garages
      # Linearly interpolate between Garage 1 and Garage 2 tables
      garage_frac_under_conditioned = get_garage_frac_under_conditioned(hpxml_bldg, location)
      heat_temp = (hpxml_bldg.header.manualj_heating_design_temp +
                   (5.0 * garage_frac_under_conditioned))

    elsif [HPXML::LocationBasementUnconditioned, HPXML::LocationCrawlspaceUnvented,
           HPXML::LocationCrawlspaceVented, HPXML::LocationGarage].include? location
      # Includes below-grade garage
      heat_temp = calculate_space_design_temp(mj, location, weather, hpxml_bldg, mj.heat_setpoint, outdoor_design_temp, ground_temp, false)

    elsif [HPXML::LocationOtherHousingUnit, HPXML::LocationOtherHeatedSpace,
           HPXML::LocationOtherMultifamilyBufferSpace, HPXML::LocationOtherNonFreezingSpace,
           HPXML::LocationExteriorWall, HPXML::LocationUnderSlab,
           HPXML::LocationManufacturedHomeBelly].include? location
      heat_temp = calculate_scheduled_space_design_temps(location, mj.heat_setpoint, outdoor_design_temp, ground_temp)

    end

    fail "Design temp heating not calculated for #{location}." if heat_temp.nil?

    return heat_temp
  end

  # Determines the cooling design temperature for the given location (space type).
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param location [String] The location of interest (HPXML::LocationXXX)
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Double] Cooling design temperature (F)
  def self.get_design_temp_cooling(mj, weather, location, hpxml_bldg)
    outdoor_design_temp = hpxml_bldg.header.manualj_cooling_design_temp
    ground_temp = weather.data.ShallowGroundMonthlyTemps.max

    if location == HPXML::LocationConditionedSpace
      cool_temp = mj.cool_setpoint

    elsif (location == HPXML::LocationAtticUnvented) || (location == HPXML::LocationAtticVented)

      attic_floors = hpxml_bldg.floors.select { |f| f.is_ceiling && [f.interior_adjacent_to, f.exterior_adjacent_to].include?(location) }
      avg_floor_rvalue = calculate_average_r_value(attic_floors)

      attic_roofs = hpxml_bldg.roofs.select { |r| r.interior_adjacent_to == location }
      avg_roof_rvalue = calculate_average_r_value(attic_roofs)

      if avg_floor_rvalue < avg_roof_rvalue
        # Attic is considered to be encapsulated. MJ8 says to use an attic
        # temperature of 95F, however alternative approaches are permissible
        if location == HPXML::LocationAtticVented
          cool_temp = outdoor_design_temp + 40.0 # This is the number from a California study with dark shingle roof and similar ventilation.
        else
          cool_temp = calculate_space_design_temp(mj, location, weather, hpxml_bldg, mj.cool_setpoint, outdoor_design_temp, ground_temp, true)
        end

      else
        # Calculate the cooling design temperature for the unconditioned attic based on Figure A12-14
        # Use an area-weighted temperature in case roof surfaces are different
        tot_roof_area = 0.0
        cool_temp = 0.0

        hpxml_bldg.roofs.each do |roof|
          next unless roof.interior_adjacent_to == location

          tot_roof_area += roof.net_area

          if location == HPXML::LocationAtticUnvented
            if not roof.radiant_barrier
              cool_temp += 150.0 * roof.net_area
            else
              cool_temp += 130.0 * roof.net_area
            end
          else
            if not roof.radiant_barrier
              if roof.roof_type == HPXML::RoofTypeAsphaltShingles
                if [HPXML::ColorDark, HPXML::ColorMediumDark].include? roof.roof_color
                  cool_temp += 130.0 * roof.net_area
                else
                  cool_temp += 120.0 * roof.net_area
                end
              elsif roof.roof_type == HPXML::RoofTypeWoodShingles
                cool_temp += 120.0 * roof.net_area
              elsif roof.roof_type == HPXML::RoofTypeMetal
                if [HPXML::ColorDark, HPXML::ColorMediumDark].include? roof.roof_color
                  cool_temp += 130.0 * roof.net_area
                elsif [HPXML::ColorMedium, HPXML::ColorLight].include? roof.roof_color
                  cool_temp += 120.0 * roof.net_area
                elsif [HPXML::ColorReflective].include? roof.roof_color
                  cool_temp += 95.0 * roof.net_area
                end
              elsif roof.roof_type == HPXML::RoofTypeClayTile
                if [HPXML::ColorDark, HPXML::ColorMediumDark].include? roof.roof_color
                  cool_temp += 110.0 * roof.net_area
                elsif [HPXML::ColorMedium, HPXML::ColorLight].include? roof.roof_color
                  cool_temp += 105.0 * roof.net_area
                elsif [HPXML::ColorReflective].include? roof.roof_color
                  cool_temp += 95.0 * roof.net_area
                end
              end
            else # with a radiant barrier
              if roof.roof_type == HPXML::RoofTypeAsphaltShingles
                if [HPXML::ColorDark, HPXML::ColorMediumDark].include? roof.roof_color
                  cool_temp += 120.0 * roof.net_area
                else
                  cool_temp += 110.0 * roof.net_area
                end
              elsif roof.roof_type == HPXML::RoofTypeWoodShingles
                cool_temp += 110.0 * roof.net_area
              elsif roof.roof_type == HPXML::RoofTypeMetal
                if [HPXML::ColorDark, HPXML::ColorMediumDark].include? roof.roof_color
                  cool_temp += 120.0 * roof.net_area
                elsif [HPXML::ColorMedium, HPXML::ColorLight].include? roof.roof_color
                  cool_temp += 110.0 * roof.net_area
                elsif [HPXML::ColorReflective].include? roof.roof_color
                  cool_temp += 95.0 * roof.net_area
                end
              elsif roof.roof_type == HPXML::RoofTypeClayTile
                if [HPXML::ColorDark, HPXML::ColorMediumDark].include? roof.roof_color
                  cool_temp += 105.0 * roof.net_area
                elsif [HPXML::ColorMedium, HPXML::ColorLight].include? roof.roof_color
                  cool_temp += 100.0 * roof.net_area
                elsif [HPXML::ColorReflective].include? roof.roof_color
                  cool_temp += 95.0 * roof.net_area
                end
              end
            end
          end # vented/unvented
        end # each roof surface

        cool_temp /= tot_roof_area

        # Adjust base CLTD for different CTD or DR
        cool_temp += (outdoor_design_temp - 95.0) + mj.daily_range_temp_adjust[mj.daily_range_num]
      end

    elsif location == HPXML::LocationGarage && hpxml_bldg.foundation_walls.count { |fw| fw.interior_adjacent_to == HPXML::LocationGarage } == 0
      # Completely above-grade garage
      # Calculate the garage cooling design temperature based on Table 4C for closed garages
      # Linearly interpolate between Garage 1 and Garage 2 tables
      garage_frac_under_conditioned = get_garage_frac_under_conditioned(hpxml_bldg, location)
      if mj.daily_range_num == 0
        cool_temp = (hpxml_bldg.header.manualj_cooling_design_temp +
                     (11.0 * garage_frac_under_conditioned) +
                     (22.0 * (1.0 - garage_frac_under_conditioned)))
      elsif mj.daily_range_num == 1
        cool_temp = (hpxml_bldg.header.manualj_cooling_design_temp +
                     (6.0 * garage_frac_under_conditioned) +
                     (17.0 * (1.0 - garage_frac_under_conditioned)))
      elsif mj.daily_range_num == 2
        cool_temp = (hpxml_bldg.header.manualj_cooling_design_temp +
                     (1.0 * garage_frac_under_conditioned) +
                     (12.0 * (1.0 - garage_frac_under_conditioned)))
      end

    elsif [HPXML::LocationBasementUnconditioned, HPXML::LocationCrawlspaceUnvented,
           HPXML::LocationCrawlspaceVented, HPXML::LocationGarage].include? location
      # Includes below-grade garage
      cool_temp = calculate_space_design_temp(mj, location, weather, hpxml_bldg, mj.cool_setpoint, outdoor_design_temp, ground_temp, false)

    elsif [HPXML::LocationOtherHousingUnit, HPXML::LocationOtherHeatedSpace,
           HPXML::LocationOtherMultifamilyBufferSpace, HPXML::LocationOtherNonFreezingSpace,
           HPXML::LocationExteriorWall, HPXML::LocationUnderSlab,
           HPXML::LocationManufacturedHomeBelly].include? location
      cool_temp = calculate_scheduled_space_design_temps(location, mj.cool_setpoint, outdoor_design_temp, ground_temp)

    end

    fail "Design temp cooling not calculated for #{location}." if cool_temp.nil?

    return cool_temp
  end

  # Estimates the fraction of garage under conditioned space from adjacent surfaces.
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param location [String] The location of interest (HPXML::LocationXXX)
  # @return [Double] Garage fraction under conditioned space
  def self.get_garage_frac_under_conditioned(hpxml_bldg, location)
    area_total = 0.0
    area_conditioned = 0.0
    hpxml_bldg.roofs.each do |roof|
      next unless roof.interior_adjacent_to == location

      area_total += roof.area
    end
    hpxml_bldg.floors.each do |floor|
      next unless [floor.interior_adjacent_to, floor.exterior_adjacent_to].include? location

      area_total += floor.area
      area_conditioned += floor.area if floor.is_thermal_boundary
    end
    if area_total == 0
      return 0.5
    end

    return area_conditioned / area_total
  end

  # Initializes zone/space load hashes.
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Array<Hash, Hash>] Map of HPXML::Zones => DesignLoadValues object, Map of HPXML::Spaces => DesignLoadValues object
  def self.init_loads(hpxml_bldg)
    '''
    Initial Zone/Space design loads
    '''
    all_zone_loads = {}
    all_space_loads = {}

    hpxml_bldg.conditioned_zones.each do |zone|
      all_zone_loads[zone] = DesignLoadValues.new
      zone.spaces.each do |space|
        all_space_loads[space] = DesignLoadValues.new
        space.additional_properties.total_exposed_wall_area = 0.0 # Wall area in contact with outdoor air
        # Initialize Hourly Aggregate Fenestration Loads (AFL)
        space.additional_properties.afl_hr_windows = [0.0] * 12 # Data saved for peak load
        space.additional_properties.afl_hr_skylights = [0.0] * 12 # Data saved for peak load
      end
    end

    return all_zone_loads, all_space_loads
  end

  # Calculates heating and cooling loads for windows & skylights.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_windows_skylights(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    # Average cooling load factors (CLF) for windows/skylights WITHOUT internal shading (MJ8 Table 3D-3)
    clf_avg_nois = [0.24, 0.35, 0.38, 0.4, 0.48, 0.4, 0.38, 0.35, 0.24]
    clf_avg_nois_horiz = 0.68

    # Average cooling load factors (CLF) for windows/skylights WITH internal shading (MJ8 Table 3D-3)
    clf_avg_is = [0.18, 0.29, 0.32, 0.32, 0.29, 0.32, 0.32, 0.29, 0.18]
    clf_avg_is_horiz = 0.52

    # Hourly cooling load factor (CLF) for windows/skylights WITHOUT internal shading (MJ8 Table A11-5)
    # Applies to both mid-summer and October calculations
    clf_hr_nois = [[0.14, 0.22, 0.34, 0.48, 0.59, 0.65, 0.65, 0.59, 0.50, 0.43, 0.36, 0.28, 0.22], # S
                   [0.10, 0.12, 0.14, 0.16, 0.24, 0.36, 0.49, 0.60, 0.66, 0.66, 0.58, 0.43, 0.33], # SW
                   [0.08, 0.10, 0.11, 0.12, 0.14, 0.20, 0.32, 0.45, 0.57, 0.64, 0.61, 0.44, 0.34], # W
                   [0.10, 0.12, 0.14, 0.16, 0.17, 0.19, 0.23, 0.33, 0.47, 0.59, 0.60, 0.43, 0.33], # NW
                   [0.48, 0.56, 0.63, 0.71, 0.76, 0.80, 0.82, 0.82, 0.79, 0.75, 0.69, 0.61, 0.48], # N
                   [0.51, 0.51, 0.45, 0.39, 0.36, 0.33, 0.31, 0.28, 0.26, 0.23, 0.19, 0.15, 0.12], # NE
                   [0.51, 0.57, 0.57, 0.50, 0.42, 0.37, 0.32, 0.29, 0.25, 0.22, 0.19, 0.15, 0.12], # E
                   [0.43, 0.55, 0.62, 0.63, 0.57, 0.48, 0.42, 0.37, 0.33, 0.28, 0.24, 0.19, 0.15], # SE
                   [0.14, 0.22, 0.34, 0.48, 0.59, 0.65, 0.65, 0.59, 0.50, 0.43, 0.36, 0.28, 0.22]] # S
    clf_hr_nois_horiz = [0.24, 0.36, 0.48, 0.58, 0.66, 0.72, 0.74, 0.73, 0.67, 0.59, 0.47, 0.37, 0.29]

    # Hourly cooling load factor (CLF) for windows/skylights WITH internal shading (MJ8 Table A11-6)
    # Applies to both mid-summer and October calculations
    clf_hr_is = [[0.23, 0.38, 0.58, 0.75, 0.83, 0.80, 0.68, 0.50, 0.35, 0.27, 0.19, 0.11, 0.09], # S
                 [0.14, 0.16, 0.19, 0.22, 0.38, 0.59, 0.75, 0.83, 0.81, 0.69, 0.45, 0.16, 0.12], # SW
                 [0.11, 0.13, 0.15, 0.16, 0.17, 0.31, 0.53, 0.72, 0.82, 0.81, 0.61, 0.16, 0.12], # W
                 [0.14, 0.17, 0.19, 0.20, 0.21, 0.22, 0.30, 0.52, 0.73, 0.82, 0.69, 0.16, 0.12], # NW
                 [0.65, 0.73, 0.80, 0.86, 0.89, 0.89, 0.86, 0.82, 0.75, 0.78, 0.91, 0.24, 0.18], # N
                 [0.74, 0.58, 0.37, 0.29, 0.27, 0.26, 0.24, 0.22, 0.20, 0.16, 0.12, 0.06, 0.05], # NE
                 [0.80, 0.76, 0.62, 0.41, 0.27, 0.24, 0.22, 0.20, 0.17, 0.14, 0.11, 0.06, 0.05], # E
                 [0.74, 0.81, 0.79, 0.68, 0.49, 0.33, 0.28, 0.25, 0.22, 0.18, 0.13, 0.08, 0.07], # SE
                 [0.23, 0.38, 0.58, 0.75, 0.83, 0.80, 0.68, 0.50, 0.35, 0.27, 0.19, 0.11, 0.09]] # S
    clf_hr_is_horiz = [0.44, 0.59, 0.72, 0.81, 0.85, 0.85, 0.81, 0.71, 0.58, 0.42, 0.25, 0.14, 0.12]

    # Mid summer Hourly Shade Line Multipliers (SLM) (MJ8 Table A11-7)
    slm_hr_lats = [28.0, 34.0, 40.0, 46.0, 52.0, 60.0] # degrees
    slm_hr = [[[5.3, 3.7, 5.3, 0.0], [3.2, 2.5, 3.2, 0.0], [2.2, 1.9, 2.2, 0.2], [1.8, 1.5, 1.8, 0.0], [1.4, 1.2, 1.4, 0.0], [1.1, 0.9, 1.1, 0.0]], # S
              [[0.0, 5.0, 1.2, 0.2], [0.0, 3.4, 1.1, 0.2], [0.0, 2.6, 0.9, 0.1], [0.0, 2.1, 0.8, 0.2], [0.0, 1.7, 0.8, 0.3], [0.0, 1.3, 0.7, 0.3]], # SW
              [[0.0, 0.0, 1.0, 0.1], [0.0, 0.0, 1.0, 0.1], [0.0, 0.0, 1.0, 0.1], [0.0, 0.0, 0.9, 0.2], [0.0, 0.0, 0.9, 0.2], [0.0, 0.0, 0.8, 0.2]], # W
              [[0.0, 0.0, 1.9, 0.1], [0.0, 0.0, 2.1, 0.1], [0.0, 0.0, 2.4, 0.0], [0.0, 0.0, 2.6, 0.2], [0.0, 0.0, 3.1, 0.2], [0.0, 0.0, 3.9, 0.2]], # NW
              [[0.0, 0.0, 0.0, 0.5], [0.0, 0.0, 0.0, 0.7], [0.0, 0.0, 0.0, 0.8], [0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.3], [0.0, 0.0, 0.0, 1.8]], # N
              [[1.9, 0.0, 0.0, 0.0], [2.1, 0.0, 0.0, 0.0], [2.4, 0.0, 0.0, 0.0], [2.6, 0.0, 0.0, 0.0], [3.1, 0.0, 0.0, 0.0], [3.9, 0.0, 0.0, 0.0]], # NE
              [[1.0, 0.0, 0.0, 0.0], [1.0, 0.0, 0.0, 0.0], [1.0, 0.0, 0.0, 0.0], [0.9, 0.0, 0.0, 0.0], [0.9, 0.0, 0.0, 0.0], [0.8, 0.0, 0.0, 0.0]], # E
              [[1.2, 5.0, 0.0, 0.0], [1.1, 3.4, 0.0, 0.0], [0.9, 2.6, 0.0, 0.0], [0.8, 2.1, 0.0, 0.0], [0.8, 1.7, 0.0, 0.0], [0.7, 1.3, 0.0, 0.0]], # SE
              [[5.3, 3.7, 5.3, 0.0], [3.2, 2.5, 3.2, 0.0], [2.2, 1.9, 2.2, 0.2], [1.8, 1.5, 1.8, 0.0], [1.4, 1.2, 1.4, 0.0], [1.1, 0.9, 1.1, 0.0]]] # S

    # Mid summer Shade Line Multiplier (SLM) Values (MJ8 Table 3E-1)
    alm_avg_lats = [25.0, 30.0, 35.0, 40.0, 45.0, 50.0]
    slm_avg = [[10.1, 5.40, 3.53, 2.60, 2.05, 1.70], # S
               [1.89, 1.63, 1.41, 1.25, 1.13, 1.01], # SW
               [0.83, 0.83, 0.82, 0.81, 0.80, 0.79], # W
               [0.0,  0.0,  0.0,  0.0,  0.0,  0.0], # NW
               [0.0,  0.0,  0.0,  0.0,  0.0,  0.0], # N
               [0.0,  0.0,  0.0,  0.0,  0.0,  0.0], # NE
               [0.83, 0.83, 0.82, 0.81, 0.80, 0.79], # E
               [1.89, 1.63, 1.41, 1.25, 1.13, 1.01], # SE
               [10.1, 5.40, 3.53, 2.60, 2.05, 1.70]] # S

    # Mid summer Peak solar factor (PSF) (MJ8 Table 3D-2)
    psf_lats = [28.0, 34.0, 40.0, 46.0, 52.0, 60.0] # degrees
    psf = [[91.0, 121.0, 149.0, 173.0, 193.0, 211.0], # S
           [172.0, 185.0, 196.0, 205.0, 212.0, 217.0], # SW
           [220.0, 219.0, 216.0, 213.0, 208.0, 199.0], # W
           [149.0, 140.0, 135.0, 130.0, 124.0, 114.0], # NW
           [38.0,  37.0,  35.0,  34.0,  32.0,  28.0], # N
           [149.0, 140.0, 135.0, 130.0, 124.0, 114.0], # NE
           [220.0, 219.0, 216.0, 213.0, 208.0, 199.0], # E
           [172.0, 185.0, 196.0, 205.0, 212.0, 217.0], # SE
           [91.0,  121.0, 149.0, 173.0, 193.0, 211.0]] # S
    psf_horiz = [272.0, 261.0, 247.0, 230.0, 208.0, 176.0]

    # Hourly Temperature Adjustment Values (HTA_DR) (MJ8 Table A11-3)
    # Low DR, Medium DR, High DR and Hour = 8,9, ... ,19,20
    hta = [[-6.3,  -5.0,  -3.7,  -2.5, -1.5, -0.7, -0.2, 0.0, -0.2, -0.7, -1.5, -2.5, -3.7], # Low DR
           [-12.6, -10.0, -7.4,  -5.0, -2.9, -1.3, -0.3, 0.0, -0.3, -1.3, -2.9, -5.0, -7.4], # Medium DR
           [-18.9, -15.0, -11.1, -7.5, -4.4, -2.0, -0.5, 0.0, -0.5, -2.0, -4.4, -7.5, -11.1]] # High DR

    # Determine latitude-specific values (PSF, SLM)
    psf_lat = []
    psf_lat_horiz = nil
    slm_hr_lat = []
    slm_avg_lat = []
    for cnt in 0..8 # S/SW/W/NW/N/NE/E/SE/S
      # psf/psf_horiz
      if hpxml_bldg.latitude <= psf_lats[0]
        psf_lat << psf[cnt][0]
        psf_lat_horiz = psf_horiz[0]
      elsif hpxml_bldg.latitude >= psf_lats[-1]
        psf_lat << psf[cnt][-1]
        psf_lat_horiz = psf_horiz[-1]
      else
        cnt_lat_s = psf_lats.bsearch_index { |i| hpxml_bldg.latitude < i } - 1
        psf_lat << MathTools.interp2(hpxml_bldg.latitude, psf_lats[cnt_lat_s], psf_lats[cnt_lat_s + 1], psf[cnt][cnt_lat_s], psf[cnt][cnt_lat_s + 1])
        psf_lat_horiz = MathTools.interp2(hpxml_bldg.latitude, psf_lats[cnt_lat_s], psf_lats[cnt_lat_s + 1], psf_horiz[cnt_lat_s], psf_horiz[cnt_lat_s + 1])
      end

      # slm_hr
      if hpxml_bldg.latitude <= slm_hr_lats[0]
        slm_hr_lat << slm_hr[cnt][0]
      elsif hpxml_bldg.latitude >= slm_hr_lats[-1]
        slm_hr_lat << slm_hr[cnt][-1]
      else
        cnt_lat_s = slm_hr_lats.bsearch_index { |i| hpxml_bldg.latitude < i } - 1
        inner_array = []
        for i in 0..slm_hr[0][0].size - 1
          inner_array << MathTools.interp2(hpxml_bldg.latitude, slm_hr_lats[cnt_lat_s], slm_hr_lats[cnt_lat_s + 1], slm_hr[cnt][cnt_lat_s][i], slm_hr[cnt][cnt_lat_s + 1][i])
        end
        slm_hr_lat << inner_array
      end

      # slm_avg
      if hpxml_bldg.latitude <= alm_avg_lats[0]
        slm_avg_lat << slm_avg[cnt][0]
      elsif hpxml_bldg.latitude >= alm_avg_lats[-1]
        slm_avg_lat << slm_avg[cnt][-1]
      else
        cnt_lat_s = alm_avg_lats.bsearch_index { |i| hpxml_bldg.latitude < i } - 1
        slm_avg_lat << MathTools.interp2(hpxml_bldg.latitude, alm_avg_lats[cnt_lat_s], alm_avg_lats[cnt_lat_s + 1], slm_avg[cnt][cnt_lat_s], slm_avg[cnt][cnt_lat_s + 1])
      end
    end

    # Windows
    hpxml_bldg.windows.each do |window|
      wall = window.wall
      next unless wall.is_exterior_thermal_boundary

      space = wall.space
      zone = space.zone

      window_isc = window.interior_shading_factor_summer
      window_esc = window.exterior_shading_factor_summer
      cnt45 = (get_mj_azimuth(window.azimuth) / 45.0).round.to_i

      window_ufactor, window_shgc = Constructions.get_ufactor_shgc_adjusted_by_storms(window.storm_type, window.ufactor, window.shgc)

      htg_htm = window_ufactor * mj.htd
      htg_loads = htg_htm * window.area
      all_zone_loads[zone].Heat_Windows += htg_loads
      all_space_loads[space].Heat_Windows += htg_loads

      for hr in [nil, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        # If hr == nil: Calculate the Average Load Procedure (ALP) Load
        # Else: Calculate the hourly Aggregate Fenestration Load (AFL)

        # clf_d: Average Cooling Load Factor for the given window direction
        # clf_n: Average Cooling Load Factor for a window facing North (fully shaded)
        if hr.nil?
          if window_isc < 1
            clf_d = clf_avg_is[cnt45]
            clf_n = clf_avg_is[4]
          else
            clf_d = clf_avg_nois[cnt45]
            clf_n = clf_avg_nois[4]
          end
        else
          if window_isc < 1
            clf_d = clf_hr_is[cnt45][hr]
            clf_n = clf_hr_is[4][hr]
          else
            clf_d = clf_hr_nois[cnt45][hr]
            clf_n = clf_hr_nois[4][hr]
          end
        end

        ctd_adj = mj.ctd
        if not hr.nil?
          # Calculate hourly CTD adjusted value for mid-summer
          ctd_adj += hta[mj.daily_range_num][hr]
        end

        # Hourly Heat Transfer Multiplier for the given window Direction
        htm_d = psf_lat[cnt45] * clf_d * window_shgc * window_isc / 0.87 + window_ufactor * ctd_adj
        htm_d *= window_esc

        # Hourly Heat Transfer Multiplier for a window facing North (fully shaded)
        htm_n = psf_lat[4] * clf_n * window_shgc * window_isc / 0.87 + window_ufactor * ctd_adj
        htm_n *= window_esc

        if window.overhangs_depth.to_f > 0
          if hr.nil?
            slm = slm_avg_lat[cnt45]
          elsif [0, 1, 2].include? hr # 8, 9, and 10 am: use 09:00 hours
            slm = slm_hr_lat[cnt45][0]
          elsif [3, 4, 5].include? hr # 11, 12, and 1 pm: use Noon
            slm = slm_hr_lat[cnt45][1]
          elsif [6, 7, 8].include? hr # 2, 3, and 4 pm: use 15:00 hours
            slm = slm_hr_lat[cnt45][2]
          elsif [9, 10, 11].include? hr # 2, 3, and 4 pm: use 15:00 hours
            slm = slm_hr_lat[cnt45][3]
          end

          z_sl = slm * window.overhangs_depth
          window_height = window.overhangs_distance_to_bottom_of_window - window.overhangs_distance_to_top_of_window
          if z_sl < window.overhangs_distance_to_top_of_window
            # Overhang is too short to provide shade or no adjustment for overhang shade required
            clg_htm = htm_d
          elsif z_sl < window.overhangs_distance_to_bottom_of_window
            percent_shaded = (z_sl - window.overhangs_distance_to_top_of_window) / window_height
            clg_htm = percent_shaded * htm_n + (1.0 - percent_shaded) * htm_d
          else
            # Window is entirely in the shade since the shade line is below the windowsill
            clg_htm = htm_n
          end
        else
          clg_htm = htm_d
        end

        # Block/space loads
        clg_loads = clg_htm * window.area
        if hr.nil?
          # Average Load Procedure (ALP) load
          all_zone_loads[zone].Cool_Windows += clg_loads
          window.additional_properties.detailed_output_values = DetailedOutputValues.new(area: window.area,
                                                                                         heat_htm: htg_htm,
                                                                                         cool_htm: clg_htm,
                                                                                         heat_load: htg_loads,
                                                                                         cool_load_sens: clg_loads,
                                                                                         cool_load_lat: 0)
          if space.fenestration_load_procedure == HPXML::SpaceFenestrationLoadProcedureStandard
            all_space_loads[space].Cool_Windows += clg_loads
          end
        else
          all_space_loads[space].HourlyFenestrationLoads[hr] += clg_loads
          space.additional_properties.afl_hr_windows[hr] += clg_loads if space.fenestration_load_procedure == HPXML::SpaceFenestrationLoadProcedurePeak
        end
      end
    end # window

    # Skylights
    hpxml_bldg.skylights.each do |skylight|
      roof = skylight.roof
      floor = skylight.floor # For skylights with attic shafts
      next unless roof.is_exterior_thermal_boundary || (!floor.nil? && floor.is_thermal_boundary)

      space = floor.nil? ? roof.space : floor.space
      zone = space.zone

      skylight_isc = skylight.interior_shading_factor_summer
      skylight_esc = skylight.exterior_shading_factor_summer
      cnt45 = (get_mj_azimuth(skylight.azimuth) / 45.0).round.to_i
      inclination_angle = UnitConversions.convert(Math.atan(roof.pitch / 12.0), 'rad', 'deg')

      skylight_ufactor, skylight_shgc = Constructions.get_ufactor_shgc_adjusted_by_storms(skylight.storm_type, skylight.ufactor, skylight.shgc)

      # Calculate U-effective by including curb/shaft impacts
      u_eff_skylight = skylight_ufactor
      if (not skylight.curb_area.nil?) && (not skylight.curb_assembly_r_value.nil?)
        u_curb = 1.0 / skylight.curb_assembly_r_value
        ar_curb = skylight.curb_area / skylight.area
        u_eff_skylight += u_curb * ar_curb
      end
      if (not skylight.shaft_area.nil?) && (not skylight.shaft_assembly_r_value.nil?)
        u_shaft = 1.0 / skylight.shaft_assembly_r_value
        ar_shaft = skylight.shaft_area / skylight.area
        u_eff_skylight += u_shaft * ar_shaft
      end

      htg_htm = u_eff_skylight * mj.htd
      htg_loads = htg_htm * skylight.area
      all_zone_loads[zone].Heat_Skylights += htg_loads
      all_space_loads[space].Heat_Skylights += htg_loads

      for hr in [nil, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        # If hr == nil: Calculate the Average Load Procedure (ALP) Load
        # Else: Calculate the hourly Aggregate Fenestration Load (AFL)

        # clf_d: Average Cooling Load Factor for the given skylight direction
        # clf_horiz: Average Cooling Load Factor for horizontal
        if hr.nil?
          if skylight_isc < 1
            clf_d = clf_avg_is[cnt45]
            clf_horiz = clf_avg_is_horiz
          else
            clf_d = clf_avg_nois[cnt45]
            clf_horiz = clf_avg_nois_horiz
          end
        else
          if skylight_isc < 1
            clf_d = clf_hr_is[cnt45][hr]
            clf_horiz = clf_hr_is_horiz[hr]
          else
            clf_d = clf_hr_nois[cnt45][hr]
            clf_horiz = clf_hr_nois_horiz[hr]
          end
        end

        sol_h = Math::cos(UnitConversions.convert(inclination_angle, 'deg', 'rad')) * (psf_lat_horiz * clf_horiz)
        sol_v = Math::sin(UnitConversions.convert(inclination_angle, 'deg', 'rad')) * (psf_lat[cnt45] * clf_d)

        ctd_adj = mj.ctd
        if not hr.nil?
          # Calculate hourly CTD adjusted value for mid-summer
          ctd_adj += hta[mj.daily_range_num][hr]
        end

        # Hourly Heat Transfer Multiplier for the given skylight Direction
        clg_htm = (sol_h + sol_v) * (skylight_shgc * skylight_isc / 0.87) + u_eff_skylight * (ctd_adj + 15.0)
        clg_htm *= skylight_esc

        # Block/space loads
        clg_loads = clg_htm * skylight.area
        if hr.nil?
          # Average Load Procedure (ALP) load
          all_zone_loads[zone].Cool_Skylights += clg_loads
          skylight.additional_properties.detailed_output_values = DetailedOutputValues.new(area: skylight.area,
                                                                                           heat_htm: htg_htm,
                                                                                           cool_htm: clg_htm,
                                                                                           heat_load: htg_loads,
                                                                                           cool_load_sens: clg_loads,
                                                                                           cool_load_lat: 0)
          if space.fenestration_load_procedure == HPXML::SpaceFenestrationLoadProcedureStandard
            all_space_loads[space].Cool_Skylights += clg_loads
          end
        else
          all_space_loads[space].HourlyFenestrationLoads[hr] += clg_loads
          space.additional_properties.afl_hr_skylights[hr] += clg_loads if space.fenestration_load_procedure == HPXML::SpaceFenestrationLoadProcedurePeak
        end
      end
    end # skylight

    # Check for Adequate Exposure Diversity (AED)
    # If not adequate, add AED Excursion to windows cooling load

    hpxml_bldg.conditioned_zones.each do |zone|
      # Loop spaces to calculate adjustment for each space
      zone.spaces.each do |space|
        if space.fenestration_load_procedure == HPXML::SpaceFenestrationLoadProcedureStandard
          all_space_loads[space].Cool_AEDExcursion = calculate_aed_excursion(all_space_loads[space].HourlyFenestrationLoads)
        else
          all_space_loads[space].Cool_AEDExcursion = 0.0
          all_space_loads[space].Cool_Windows = space.additional_properties.afl_hr_windows.max
          all_space_loads[space].Cool_Skylights = space.additional_properties.afl_hr_skylights.max
        end
        all_space_loads[space].HourlyFenestrationLoads.each_with_index do |load, i|
          all_zone_loads[zone].HourlyFenestrationLoads[i] += load
        end
      end
      all_zone_loads[zone].Cool_AEDExcursion = calculate_aed_excursion(all_zone_loads[zone].HourlyFenestrationLoads)
    end
  end

  # Calculates the Adequate Exposure Diversity (AED) excursion. An excursion
  # adjustment is added to the fenestration load when the home does not have
  # relatively constant fenestration loads throughout the day (e.g., a dwelling
  # unit with all windows facing the same direction).
  #
  # @param afl_hr [Array<Double>] Hourly Aggregate Fenestration Loads (Btu/hr)
  # @return [Double] AED Excursion (Btu/hr)
  def self.calculate_aed_excursion(afl_hr)
    # Daily Average Load (DAL)
    dal = afl_hr.sum(0.0) / afl_hr.size

    # Excursion Limit line (ELL)
    ell = 1.3 * dal

    # Peak Fenestration Load (PFL)
    pfl = afl_hr.max

    # Excursion Adjustment Load (EAL)
    return [0.0, pfl - ell].max
  end

  # Calculates heating and cooling loads for doors.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_doors(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    # CLTD values derived from Table 4A Construction 11 table.
    if mj.daily_range_num == 0
      cltd = mj.ctd + 15.0
    elsif mj.daily_range_num == 1
      cltd = mj.ctd + 11.0
    elsif mj.daily_range_num == 2
      cltd = mj.ctd + 6.0
    end

    hpxml_bldg.doors.each do |door|
      next unless door.is_thermal_boundary

      wall = door.wall
      space = wall.space
      zone = space.zone

      if door.wall.is_exterior
        htg_htm = (1.0 / door.r_value) * mj.htd
        clg_htm = (1.0 / door.r_value) * cltd
      else # Partition door
        adjacent_space = door.wall.exterior_adjacent_to
        htg_htm = (1.0 / door.r_value) * (mj.heat_setpoint - mj.heat_design_temps[adjacent_space])
        clg_htm = (1.0 / door.r_value) * (mj.cool_design_temps[adjacent_space] - mj.cool_setpoint)
      end
      htg_loads = htg_htm * door.area
      clg_loads = clg_htm * door.area
      all_zone_loads[zone].Heat_Doors += htg_loads
      all_zone_loads[zone].Cool_Doors += clg_loads
      all_space_loads[space].Heat_Doors += htg_loads
      all_space_loads[space].Cool_Doors += clg_loads
      door.additional_properties.detailed_output_values = DetailedOutputValues.new(area: door.area,
                                                                                   heat_htm: htg_htm,
                                                                                   cool_htm: clg_htm,
                                                                                   heat_load: htg_loads,
                                                                                   cool_load_sens: clg_loads,
                                                                                   cool_load_lat: 0)
    end
  end

  # Calculates heating and cooling loads for above-grade and below-grade HPXML walls.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_walls(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    # Above-Grade Walls
    (hpxml_bldg.walls + hpxml_bldg.rim_joists).each do |wall|
      next unless wall.is_thermal_boundary

      space = wall.space
      zone = space.zone

      ashrae_wall_group = get_ashrae_wall_group(wall)

      if wall.is_exterior
        # Store exposed wall gross area for infiltration calculation
        space.additional_properties.total_exposed_wall_area += wall.area

        # Adjust base Cooling Load Temperature Difference (CLTD)
        # Assume absorptivity for light walls < 0.5, medium walls <= 0.75, dark walls > 0.75 (based on MJ8 Table 4B Notes)
        if wall.solar_absorptance <= 0.5
          color_multiplier = 0.65      # MJ8 Table 4B Notes, pg 348
        elsif wall.solar_absorptance <= 0.75
          color_multiplier = 0.83      # MJ8 Appendix 12, pg 519
        else
          color_multiplier = 1.0
        end

        # Base Cooling Load Temperature Differences (CLTD's) for dark colored sunlit and shaded walls
        # with 95 degF outside temperature taken from MJ8 Figure A12-8 (intermediate wall groups were
        # determined using linear interpolation). Shaded walls apply to partition walls only.
        cltd_base_sun = { 'G' => 38.0, 'F-G' => 34.95, 'F' => 31.9, 'E-F' => 29.45, 'E' => 27.0, 'D-E' => 24.5, 'D' => 22.0, 'C-D' => 21.25, 'C' => 20.5, 'B-C' => 19.65, 'B' => 18.8 }
        # cltd_base_shade = { 'G' => 25.0, 'F-G' => 22.5, 'F' => 20.0, 'E-F' => 18.45, 'E' => 16.9, 'D-E' => 15.45, 'D' => 14.0, 'C-D' => 13.55, 'C' => 13.1, 'B-C' => 12.85, 'B' => 12.6 }

        # Non-directional exterior walls
        cltd_base = cltd_base_sun
        cltd = cltd_base[ashrae_wall_group] * color_multiplier

        if mj.ctd >= 10.0
          # Adjust base CLTD for different CTD or DR
          cltd += (hpxml_bldg.header.manualj_cooling_design_temp - 95.0) + mj.daily_range_temp_adjust[mj.daily_range_num]
        else
          # Handling cases ctd < 10 is based on A12-18 in MJ8
          cltd_corr = mj.ctd - 20.0 - mj.daily_range_temp_adjust[mj.daily_range_num]
          cltd = [cltd + cltd_corr, 0.0].max # NOTE: The CLTD_Alt equation in A12-18 part 5 suggests CLTD - CLTD_corr, but A12-19 suggests it should be CLTD + CLTD_corr (where CLTD_corr is negative)
        end

        clg_htm = (1.0 / wall.insulation_assembly_r_value) * cltd
        htg_htm = (1.0 / wall.insulation_assembly_r_value) * mj.htd
      else # Partition wall
        adjacent_space = wall.exterior_adjacent_to
        clg_htm = (1.0 / wall.insulation_assembly_r_value) * (mj.cool_design_temps[adjacent_space] - mj.cool_setpoint)
        htg_htm = (1.0 / wall.insulation_assembly_r_value) * (mj.heat_setpoint - mj.heat_design_temps[adjacent_space])
      end
      clg_loads = clg_htm * wall.net_area
      htg_loads = htg_htm * wall.net_area
      all_zone_loads[zone].Cool_Walls += clg_loads
      all_zone_loads[zone].Heat_Walls += htg_loads
      all_space_loads[space].Cool_Walls += clg_loads
      all_space_loads[space].Heat_Walls += htg_loads
      wall.additional_properties.detailed_output_values = DetailedOutputValues.new(area: wall.net_area,
                                                                                   heat_htm: htg_htm,
                                                                                   cool_htm: clg_htm,
                                                                                   heat_load: htg_loads,
                                                                                   cool_load_sens: clg_loads,
                                                                                   cool_load_lat: 0)
    end

    # Foundation walls
    hpxml_bldg.foundation_walls.each do |foundation_wall|
      next unless foundation_wall.is_thermal_boundary

      space = foundation_wall.space
      zone = space.zone

      if foundation_wall.is_exterior
        # Store exposed wall gross area for infiltration calculation
        ag_frac = (foundation_wall.height - foundation_wall.depth_below_grade) / foundation_wall.height
        space.additional_properties.total_exposed_wall_area += foundation_wall.area * ag_frac

        u_wall_with_soil = get_foundation_wall_ufactor(foundation_wall, true, mj.ground_conductivity)
        htg_htm = u_wall_with_soil * mj.htd
      else # Partition wall
        adjacent_space = foundation_wall.exterior_adjacent_to
        u_wall_without_soil = get_foundation_wall_ufactor(foundation_wall, false, mj.ground_conductivity)
        htg_htm = u_wall_without_soil * (mj.heat_setpoint - mj.heat_design_temps[adjacent_space])
      end
      htg_loads = htg_htm * foundation_wall.net_area
      all_zone_loads[zone].Heat_Walls += htg_loads
      all_space_loads[space].Heat_Walls += htg_loads
      foundation_wall.additional_properties.detailed_output_values = DetailedOutputValues.new(area: foundation_wall.net_area,
                                                                                              heat_htm: htg_htm,
                                                                                              cool_htm: 0,
                                                                                              heat_load: htg_loads,
                                                                                              cool_load_sens: 0,
                                                                                              cool_load_lat: 0)
    end
  end

  # Calculates heating and cooling loads for roofs.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_roofs(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    hpxml_bldg.roofs.each do |roof|
      next unless roof.is_thermal_boundary

      space = roof.space
      zone = space.zone

      # Base CLTD for conditioned roofs (Roof-Joist-Ceiling Sandwiches) taken from MJ8 Figure A12-16
      if roof.insulation_assembly_r_value <= 6
        cltd = 50.0
      elsif roof.insulation_assembly_r_value <= 13
        cltd = 45.0
      elsif roof.insulation_assembly_r_value <= 15
        cltd = 38.0
      elsif roof.insulation_assembly_r_value <= 21
        cltd = 31.0
      elsif roof.insulation_assembly_r_value <= 30
        cltd = 30.0
      else
        cltd = 27.0
      end

      # Base CLTD color adjustment based on notes in MJ8 Figure A12-16
      if [HPXML::ColorDark, HPXML::ColorMediumDark].include? roof.roof_color
        if [HPXML::RoofTypeClayTile, HPXML::RoofTypeWoodShingles].include? roof.roof_type
          cltd *= 0.83
        end
      elsif [HPXML::ColorMedium, HPXML::ColorLight].include? roof.roof_color
        if [HPXML::RoofTypeClayTile].include? roof.roof_type
          cltd *= 0.65
        else
          cltd *= 0.83
        end
      elsif [HPXML::ColorReflective].include? roof.roof_color
        if [HPXML::RoofTypeAsphaltShingles, HPXML::RoofTypeWoodShingles].include? roof.roof_type
          cltd *= 0.83
        else
          cltd *= 0.65
        end
      end

      # Adjust base CLTD for different CTD or DR
      cltd += (hpxml_bldg.header.manualj_cooling_design_temp - 95.0) + mj.daily_range_temp_adjust[mj.daily_range_num]

      clg_htm = (1.0 / roof.insulation_assembly_r_value) * cltd
      htg_htm = (1.0 / roof.insulation_assembly_r_value) * mj.htd
      clg_loads = clg_htm * roof.net_area
      htg_loads = htg_htm * roof.net_area
      all_zone_loads[zone].Cool_Roofs += clg_loads
      all_zone_loads[zone].Heat_Roofs += htg_loads
      all_space_loads[space].Cool_Roofs += clg_loads
      all_space_loads[space].Heat_Roofs += htg_loads
      roof.additional_properties.detailed_output_values = DetailedOutputValues.new(area: roof.net_area,
                                                                                   heat_htm: htg_htm,
                                                                                   cool_htm: clg_htm,
                                                                                   heat_load: htg_loads,
                                                                                   cool_load_sens: clg_loads,
                                                                                   cool_load_lat: 0)
    end
  end

  # Calculates heating and cooling loads for ceilings.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_ceilings(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    hpxml_bldg.floors.each do |floor|
      next unless floor.is_ceiling
      next unless floor.is_thermal_boundary

      space = floor.space
      zone = space.zone

      if floor.is_exterior
        clg_htm = (1.0 / floor.insulation_assembly_r_value) * (mj.ctd - 5.0 + mj.daily_range_temp_adjust[mj.daily_range_num])
        htg_htm = (1.0 / floor.insulation_assembly_r_value) * mj.htd
      else
        adjacent_space = floor.exterior_adjacent_to
        clg_htm = (1.0 / floor.insulation_assembly_r_value) * (mj.cool_design_temps[adjacent_space] - mj.cool_setpoint)
        htg_htm = (1.0 / floor.insulation_assembly_r_value) * (mj.heat_setpoint - mj.heat_design_temps[adjacent_space])
      end
      clg_loads = clg_htm * floor.net_area
      htg_loads = htg_htm * floor.net_area
      all_zone_loads[zone].Cool_Ceilings += clg_loads
      all_zone_loads[zone].Heat_Ceilings += htg_loads
      all_space_loads[space].Cool_Ceilings += clg_loads
      all_space_loads[space].Heat_Ceilings += htg_loads
      floor.additional_properties.detailed_output_values = DetailedOutputValues.new(area: floor.net_area,
                                                                                    heat_htm: htg_htm,
                                                                                    cool_htm: clg_htm,
                                                                                    heat_load: htg_loads,
                                                                                    cool_load_sens: clg_loads,
                                                                                    cool_load_lat: 0)
    end
  end

  # Calculates heating and cooling loads for floors.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_floors(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    hpxml_bldg.floors.each do |floor|
      next unless floor.is_floor
      next unless floor.is_thermal_boundary

      space = floor.space
      zone = space.zone

      has_radiant_floor = get_has_radiant_floor(zone)

      if floor.is_exterior
        htd_adj = mj.htd
        htd_adj += 25.0 if has_radiant_floor # Table 4A: Radiant floor over open crawlspace: HTM = U-Value × (HTD + 25)

        clg_htm = (1.0 / floor.insulation_assembly_r_value) * (mj.ctd - 5.0 + mj.daily_range_temp_adjust[mj.daily_range_num])
        htg_htm = (1.0 / floor.insulation_assembly_r_value) * htd_adj
      else # Partition floor
        adjacent_space = floor.exterior_adjacent_to
        if floor.is_floor && [HPXML::LocationCrawlspaceVented, HPXML::LocationCrawlspaceUnvented, HPXML::LocationBasementUnconditioned].include?(adjacent_space)
          u_floor = 1.0 / floor.insulation_assembly_r_value

          sum_ua_wall = 0.0
          sum_a_wall = 0.0
          hpxml_bldg.foundation_walls.each do |foundation_wall|
            next unless foundation_wall.is_exterior && foundation_wall.interior_adjacent_to == adjacent_space

            u_wall_without_soil = get_foundation_wall_ufactor(foundation_wall, false, mj.ground_conductivity)
            sum_a_wall += foundation_wall.net_area
            sum_ua_wall += (u_wall_without_soil * foundation_wall.net_area)
          end
          hpxml_bldg.walls.each do |wall|
            next unless wall.is_exterior && wall.interior_adjacent_to == adjacent_space

            sum_a_wall += wall.net_area
            sum_ua_wall += (1.0 / wall.insulation_assembly_r_value * wall.net_area)
          end
          fail 'Could not find connected walls.' if sum_a_wall <= 0

          u_wall = sum_ua_wall / sum_a_wall

          htd_adj = mj.htd
          htd_adj += 25.0 if has_radiant_floor && HPXML::LocationCrawlspaceVented # Table 4A: Radiant floor over open crawlspace: HTM = U-Value × (HTD + 25)

          # Calculate partition temperature different cooling (PTDC) per Manual J Figure A12-17
          # Calculate partition temperature different heating (PTDH) per Manual J Figure A12-6
          if [HPXML::LocationCrawlspaceVented].include? adjacent_space
            # Vented or Leaky
            ptdc_floor = mj.ctd / (1.0 + (4.0 * u_floor) / (u_wall + 0.11))
            ptdh_floor = htd_adj / (1.0 + (4.0 * u_floor) / (u_wall + 0.11))
          elsif [HPXML::LocationCrawlspaceUnvented, HPXML::LocationBasementUnconditioned].include? adjacent_space
            # Sealed Tight
            ptdc_floor = u_wall * mj.ctd / (4.0 * u_floor + u_wall)
            ptdh_floor = u_wall * htd_adj / (4.0 * u_floor + u_wall)
          end

          clg_htm = (1.0 / floor.insulation_assembly_r_value) * ptdc_floor
          htg_htm = (1.0 / floor.insulation_assembly_r_value) * ptdh_floor
        else # E.g., floor over garage
          clg_htm = (1.0 / floor.insulation_assembly_r_value) * (mj.cool_design_temps[adjacent_space] - mj.cool_setpoint)
          htg_htm = (1.0 / floor.insulation_assembly_r_value) * (mj.heat_setpoint - mj.heat_design_temps[adjacent_space])
        end
      end
      clg_loads = clg_htm * floor.net_area
      htg_loads = htg_htm * floor.net_area
      all_zone_loads[zone].Cool_Floors += clg_loads
      all_zone_loads[zone].Heat_Floors += htg_loads
      all_space_loads[space].Cool_Roofs += clg_loads
      all_space_loads[space].Heat_Roofs += htg_loads
      floor.additional_properties.detailed_output_values = DetailedOutputValues.new(area: floor.net_area,
                                                                                    heat_htm: htg_htm,
                                                                                    cool_htm: clg_htm,
                                                                                    heat_load: htg_loads,
                                                                                    cool_load_sens: clg_loads,
                                                                                    cool_load_lat: 0)
    end
  end

  # Calculates heating loads for slabs.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_slabs(mj, hpxml_bldg, all_zone_loads, all_space_loads)
    hpxml_bldg.slabs.each do |slab|
      next unless slab.is_thermal_boundary

      space = slab.space
      zone = space.zone

      has_radiant_floor = get_has_radiant_floor(zone)

      htd_adj = mj.htd
      htd_adj += 25.0 if has_radiant_floor # Table 4A: Radiant slab floor: HTM = F-Value × (HTD + 25)

      if slab.interior_adjacent_to == HPXML::LocationConditionedSpace # Slab-on-grade
        f_value = calc_slab_f_value(slab, mj.ground_conductivity)
        htg_htm = f_value * htd_adj
        htg_loads = htg_htm * slab.exposed_perimeter
        slab_length = slab.exposed_perimeter
      elsif HPXML::conditioned_below_grade_locations.include? slab.interior_adjacent_to
        ext_fnd_walls = hpxml_bldg.foundation_walls.select { |fw| fw.interior_adjacent_to == slab.interior_adjacent_to && fw.is_exterior }

        # Calculate weighted-average (by length) below-grade depth
        z_f = ext_fnd_walls.map { |fw| fw.depth_below_grade * (fw.area / fw.height) }.sum(0.0) / ext_fnd_walls.map { |fw| fw.area / fw.height }.sum

        # Calculate width of shortest side
        lengths_by_azimuth = {}
        ext_fnd_walls.each do |fnd_wall|
          if fnd_wall.azimuth.nil?
            azimuths = [0, 90, 180, 270]
          else
            azimuths = [fnd_wall.azimuth]
          end
          azimuths.each do |azimuth|
            lengths_by_azimuth[azimuth] = 0 if lengths_by_azimuth[azimuth].nil?
            if not fnd_wall.length.nil?
              length = fnd_wall.length
            else
              length = fnd_wall.area / fnd_wall.height
            end
            lengths_by_azimuth[azimuth] += length / azimuths.size
          end
        end
        w_b = lengths_by_azimuth.values.min

        slab_is_insulated = false
        if slab.under_slab_insulation_width.to_f > 0 && slab.under_slab_insulation_r_value > 0
          slab_is_insulated = true
        elsif slab.perimeter_insulation_depth > 0 && slab.perimeter_insulation_r_value > 0
          slab_is_insulated = true
        elsif slab.under_slab_insulation_spans_entire_slab && slab.under_slab_insulation_r_value > 0
          slab_is_insulated = true
        end

        u_value = calc_basement_slab_ufactor(slab_is_insulated, z_f, w_b, mj.ground_conductivity)
        htg_htm = u_value * htd_adj
        htg_loads = htg_htm * slab.area
        slab_area = slab.area
      end
      all_zone_loads[zone].Heat_Slabs += htg_loads
      all_space_loads[space].Heat_Slabs += htg_loads
      slab.additional_properties.detailed_output_values = DetailedOutputValues.new(area: slab_area,
                                                                                   length: slab_length,
                                                                                   heat_htm: htg_htm,
                                                                                   cool_htm: 0,
                                                                                   heat_load: htg_loads,
                                                                                   cool_load_sens: 0,
                                                                                   cool_load_lat: 0)
    end
  end

  # Calculates heating and cooling loads for infiltration and whole-building ventilation.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @param weather [WeatherFile] Weather object containing EPW information
  # @return [void]
  def self.process_load_infiltration_ventilation(mj, hpxml_bldg, all_zone_loads, all_space_loads, weather)
    cfa = hpxml_bldg.building_construction.conditioned_floor_area
    measurement = Airflow.get_infiltration_measurement_of_interest(hpxml_bldg, manualj_infiltration_method: hpxml_bldg.header.manualj_infiltration_method)
    if hpxml_bldg.header.manualj_infiltration_method == HPXML::ManualJInfiltrationMethodBlowerDoor
      infil_values = Airflow.get_values_from_air_infiltration_measurements(hpxml_bldg, cfa, weather)
      sla = infil_values[:sla] * infil_values[:a_ext]
      ela = sla * cfa
      ncfl_ag = hpxml_bldg.building_construction.number_of_conditioned_floors_above_grade

      # Determine if we are in a higher or lower shielding class
      # Combines the effects of terrain and wind shielding
      shielding_class = 4
      if hpxml_bldg.site.shielding_of_home == HPXML::ShieldingWellShielded
        shielding_class += 1
      elsif hpxml_bldg.site.shielding_of_home == HPXML::ShieldingExposed
        shielding_class -= 1
      end
      if hpxml_bldg.site.site_type == HPXML::SiteTypeUrban
        shielding_class += 1
      elsif hpxml_bldg.site.site_type == HPXML::SiteTypeRural
        shielding_class -= 1
      end
      shielding_class = [[shielding_class, 5].min, 1].max

      # Set stack/wind coefficients from Tables 5D/5E
      c_s = 0.015 * ncfl_ag
      c_w = (0.0065 - 0.00266 * (shielding_class - 3)) * ncfl_ag**0.4

      ela_in2 = UnitConversions.convert(ela, 'ft^2', 'in^2')
      windspeed_cooling_mph = 7.5 # Table 5D/5E Wind Velocity Value footnote
      windspeed_heating_mph = 15.0 # Table 5D/5E Wind Velocity Value footnote

      # Calculate infiltration airflow rates
      icfm_cool = ela_in2 * (c_s * mj.ctd + c_w * windspeed_cooling_mph**2)**0.5
      icfm_heat = ela_in2 * (c_s * mj.htd + c_w * windspeed_heating_mph**2)**0.5

    elsif hpxml_bldg.header.manualj_infiltration_method == HPXML::ManualJInfiltrationMethodDefaultTable
      ach_htg, ach_clg = get_mj_default_ach_values(hpxml_bldg, measurement.leakiness_description, cfa)
      ag_volume = hpxml_bldg.above_grade_conditioned_volume()
      icfm_cool = (ach_clg * ag_volume) / 60.0
      icfm_heat = (ach_htg * ag_volume) / 60.0
    else
      fail 'Unexpected error.'
    end

    # Check for fireplace (for heating infiltration adjustment)
    has_fireplace = false
    if hpxml_bldg.fuel_loads.count { |fl| fl.fuel_load_type == HPXML::FuelLoadTypeFireplace } > 0
      has_fireplace = true
    end
    if hpxml_bldg.heating_systems.count { |htg| htg.heating_system_type == HPXML::HVACTypeFireplace } > 0
      has_fireplace = true
    end
    if has_fireplace
      icfm_heat += 20.0 # Assume 1 fireplace, average leakiness (note: this can be different than the leakiness of the house)
    end

    # Calculate ventilation airflow rates
    ventilation_data = get_ventilation_data(hpxml_bldg)
    q_imb = ventilation_data[:q_imb]
    q_oa = ventilation_data[:q_oa]
    q_preheat = ventilation_data[:q_preheat]
    q_precool = ventilation_data[:q_precool]
    q_recirc = ventilation_data[:q_recirc]
    oa_sens_eff = ventilation_data[:oa_sens_eff]
    oa_lat_eff = ventilation_data[:oa_lat_eff]

    # Calculate net infiltration cfm (NCFM; infiltration combined with imbalanced supply ventilation)
    if q_imb == 0
      # Neutral pressure, so NCFM = ICFM
      infil_ncfm_heat = icfm_heat
      infil_ncfm_cool = icfm_cool
    elsif q_imb > 0
      # Negative pressure, so NCFM = (ICFM^1.5 + CFMimb^1.5)^0.67
      infil_ncfm_heat = (icfm_heat**1.5 + q_imb**1.5)**0.67
      infil_ncfm_cool = (icfm_cool**1.5 + q_imb**1.5)**0.67
    else
      if icfm_heat < q_imb.abs
        # Dominating positive pressure, so NCFM = 0
        infil_ncfm_heat = 0.0
      else
        # Mitigating positive pressure, so NCFM = (ICFM^1.5 - ABS(CFMimb)^1.5)^0.67
        infil_ncfm_heat = (icfm_heat**1.5 - q_imb.abs**1.5)**0.67
      end
      if icfm_cool < q_imb.abs
        # Dominating positive pressure, so NCFM = 0
        infil_ncfm_cool = 0.0
      else
        # Mitigating positive pressure, so NCFM = (ICFM^1.5 - ABS(CFMimb)^1.5)^0.67
        infil_ncfm_cool = (icfm_cool**1.5 - q_imb.abs**1.5)**0.67
      end
    end

    hpxml_bldg.additional_properties.infil_heat_cfm = infil_ncfm_heat
    hpxml_bldg.additional_properties.infil_cool_cfm = infil_ncfm_cool

    # Infiltration load
    bldg_Heat_Infil = 1.1 * mj.acf * infil_ncfm_heat * mj.htd
    bldg_Cool_Infil_Sens = 1.1 * mj.acf * infil_ncfm_cool * mj.ctd
    bldg_Cool_Infil_Lat = 0.68 * mj.acf * infil_ncfm_cool * mj.cool_design_grains

    # Calculate vent (supply) cfm
    vent_cfm_heat = q_oa
    vent_cfm_cool = q_oa

    hpxml_bldg.additional_properties.vent_heat_cfm = vent_cfm_heat
    hpxml_bldg.additional_properties.vent_cool_cfm = vent_cfm_cool

    # Calculate vent cfm incorporating sens/lat effectiveness, preheat/precool, and recirc
    vent_cfm_heat = q_oa * (1.0 - oa_sens_eff) - q_preheat - q_recirc
    vent_cfm_cool_sens = q_oa * (1.0 - oa_sens_eff) - q_precool - q_recirc
    vent_cfm_cool_lat = q_oa * (1.0 - oa_lat_eff) - q_recirc

    bldg_Heat_Vent = 1.1 * mj.acf * vent_cfm_heat * mj.htd
    bldg_Cool_Vent_Sens = 1.1 * mj.acf * vent_cfm_cool_sens * mj.ctd
    bldg_Cool_Vent_Lat = 0.68 * mj.acf * vent_cfm_cool_lat * mj.cool_design_grains

    # Apportion to zones/spaces
    bldg_exposed_wall_area = hpxml_bldg.conditioned_zones.map { |zone| zone.spaces.map { |space| space.additional_properties.total_exposed_wall_area } }.flatten.sum
    hpxml_bldg.conditioned_zones.each do |zone|
      # Ventilation assignment by floor area
      all_zone_loads[zone].Heat_Vent = bldg_Heat_Vent * zone.floor_area / cfa
      all_zone_loads[zone].Cool_Vent_Sens = bldg_Cool_Vent_Sens * zone.floor_area / cfa
      all_zone_loads[zone].Cool_Vent_Lat = bldg_Cool_Vent_Lat * zone.floor_area / cfa

      # Infiltration assignment by exterior wall area
      zone.spaces.each do |space|
        space.additional_properties.wall_area_ratio = space.additional_properties.total_exposed_wall_area / bldg_exposed_wall_area
        all_space_loads[space].Heat_Infil = bldg_Heat_Infil * space.additional_properties.wall_area_ratio
        all_space_loads[space].Cool_Infil_Sens = bldg_Cool_Infil_Sens * space.additional_properties.wall_area_ratio
      end
      zone_wall_area_ratio = zone.spaces.map { |space| space.additional_properties.total_exposed_wall_area }.sum / bldg_exposed_wall_area
      all_zone_loads[zone].Heat_Infil = bldg_Heat_Infil * zone_wall_area_ratio
      all_zone_loads[zone].Cool_Infil_Sens = bldg_Cool_Infil_Sens * zone_wall_area_ratio
      all_zone_loads[zone].Cool_Infil_Lat = bldg_Cool_Infil_Lat * zone_wall_area_ratio
    end
  end

  # Calculates cooling loads for internal gains.
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.process_load_internal_gains(hpxml_bldg, all_zone_loads, all_space_loads)
    hpxml_bldg.conditioned_zones.each do |zone|
      zone_manualj_num_occupants = zone.spaces.map { |space| space.manualj_num_occupants }.sum
      zone_manualj_internal_loads_sensible = zone.spaces.map { |space| space.manualj_internal_loads_sensible }.sum
      zone_manualj_internal_loads_latent = zone.spaces.map { |space| space.manualj_internal_loads_latent }.sum

      all_zone_loads[zone].Cool_IntGains_Sens = zone_manualj_internal_loads_sensible + 230.0 * zone_manualj_num_occupants
      all_zone_loads[zone].Cool_IntGains_Lat = zone_manualj_internal_loads_latent + 200.0 * zone_manualj_num_occupants

      zone.spaces.each do |space|
        all_space_loads[space].Cool_IntGains_Sens = space.manualj_internal_loads_sensible + 230.0 * space.manualj_num_occupants
      end
    end
  end

  # Aggregates component design loads to totals; updates the object that is passed in.
  #
  # @param loads [DesignLoadValues] Object with component design loads
  # @return [void]
  def self.aggregate_loads_to_totals(loads)
    # Heating
    loads.Heat_Tot = loads.Heat_Windows + loads.Heat_Skylights +
                     loads.Heat_Doors + loads.Heat_Walls +
                     loads.Heat_Floors + loads.Heat_Slabs +
                     loads.Heat_Ceilings + loads.Heat_Roofs +
                     loads.Heat_Infil + loads.Heat_Vent +
                     loads.Heat_Piping

    # Cooling
    loads.Cool_Sens = loads.Cool_Windows + loads.Cool_Skylights +
                      loads.Cool_Doors + loads.Cool_Walls +
                      loads.Cool_Floors + loads.Cool_Ceilings +
                      loads.Cool_Roofs + loads.Cool_Infil_Sens +
                      loads.Cool_IntGains_Sens + loads.Cool_Slabs +
                      loads.Cool_AEDExcursion + loads.Cool_Vent_Sens +
                      loads.Cool_BlowerHeat
    loads.Cool_Lat = loads.Cool_Infil_Lat + loads.Cool_Vent_Lat +
                     loads.Cool_IntGains_Lat
    loads.Cool_Tot = loads.Cool_Sens + loads.Cool_Lat
  end

  # Determine HVAC Leaving Air Temperature (LAT) and/or Supply Air Temperature (SAT).
  # Values are assigned to the hvac_cooling/hvac_heating objects.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @return [void]
  def self.apply_hvac_air_temperatures(mj, zone_loads, hvac_heating, hvac_cooling)
    if not hvac_cooling.nil?
      cooling_type = get_hvac_cooling_type(hvac_cooling)

      # Calculate Leaving Air Temperature
      if cooling_type == HPXML::HVACTypeEvaporativeCooler
        # Evaporative cooler temperature calculation based on Manual S Figure 4-7
        td_potential = mj.cool_design_temps[HPXML::LocationOutside] - mj.cool_outdoor_wetbulb
        td = td_potential * hvac_cooling.additional_properties.effectiveness
        hvac_cooling.additional_properties.leaving_air_temp = mj.cool_design_temps[HPXML::LocationOutside] - td
      else
        # Determine the Leaving Air Temperature (LAT) based on Manual S Table 1-4
        shr = [zone_loads.Cool_Sens / zone_loads.Cool_Tot, 1.0].min
        if shr < 0.80
          hvac_cooling.additional_properties.leaving_air_temp = 54.0 # F
        elsif shr < 0.85
          # MJ8 says to use 56 degF in this SHR range. Linear interpolation provides a more
          # continuous supply air flow rate across building efficiency levels.
          hvac_cooling.additional_properties.leaving_air_temp = ((58.0 - 54.0) / (0.85 - 0.80)) * (shr - 0.8) + 54.0 # F
        else
          hvac_cooling.additional_properties.leaving_air_temp = 58.0 # F
        end
      end
    end

    if not hvac_heating.nil?
      # Calculate Supply Air Temperature
      if hvac_heating.is_a? HPXML::HeatPump
        hvac_heating.additional_properties.supply_air_temp = 105.0 # F
      else
        hvac_heating.additional_properties.supply_air_temp = 120.0 # F
      end
    elsif not hvac_cooling.nil? && hvac_cooling.has_integrated_heating
      hvac_cooling.additional_properties.supply_air_temp = 120.0 # F
    end
  end

  # Updates the design loads served by the HVAC system to incorporate the fraction of the zone loads
  # served by the HVAC system.
  #
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @param frac_zone_heat_load_served [Double] Fraction of zone heating load served by this HVAC system
  # @param frac_zone_cool_load_served [Double] Fraction of zone cooling load served by this HVAC system
  # @return [void]
  def self.apply_fractions_load_served(hvac_heating, hvac_loads, frac_zone_heat_load_served, frac_zone_cool_load_served)
    # Heating Loads
    if get_hvac_heating_type(hvac_heating) == HPXML::HVACTypeHeatPumpWaterLoopToAir
      # Size to meet original fraction load served (not adjusted value from HVAC.apply_shared_heating_systems()
      # This ensures, e.g., that an appropriate heating airflow is used for duct losses.
      frac_zone_heat_load_served /= (1.0 / hvac_heating.heating_efficiency_cop)
    end
    hvac_loads.Heat_Tot *= frac_zone_heat_load_served
    hvac_loads.Heat_Walls *= frac_zone_heat_load_served
    hvac_loads.Heat_Ceilings *= frac_zone_heat_load_served
    hvac_loads.Heat_Roofs *= frac_zone_heat_load_served
    hvac_loads.Heat_Floors *= frac_zone_heat_load_served
    hvac_loads.Heat_Slabs *= frac_zone_heat_load_served
    hvac_loads.Heat_Windows *= frac_zone_heat_load_served
    hvac_loads.Heat_Skylights *= frac_zone_heat_load_served
    hvac_loads.Heat_Doors *= frac_zone_heat_load_served
    hvac_loads.Heat_Infil *= frac_zone_heat_load_served
    hvac_loads.Heat_Vent *= frac_zone_heat_load_served
    hvac_loads.Heat_Piping *= frac_zone_heat_load_served
    hvac_loads.Heat_Ducts *= frac_zone_heat_load_served

    # Cooling Loads
    hvac_loads.Cool_Tot *= frac_zone_cool_load_served
    hvac_loads.Cool_Sens *= frac_zone_cool_load_served
    hvac_loads.Cool_Lat *= frac_zone_cool_load_served
    hvac_loads.Cool_Walls *= frac_zone_cool_load_served
    hvac_loads.Cool_Ceilings *= frac_zone_cool_load_served
    hvac_loads.Cool_Roofs *= frac_zone_cool_load_served
    hvac_loads.Cool_Floors *= frac_zone_cool_load_served
    hvac_loads.Cool_Slabs *= frac_zone_cool_load_served
    hvac_loads.Cool_Windows *= frac_zone_cool_load_served
    hvac_loads.Cool_Skylights *= frac_zone_cool_load_served
    hvac_loads.Cool_AEDExcursion *= frac_zone_cool_load_served
    hvac_loads.Cool_Doors *= frac_zone_cool_load_served
    hvac_loads.Cool_Infil_Sens *= frac_zone_cool_load_served
    hvac_loads.Cool_Vent_Sens *= frac_zone_cool_load_served
    hvac_loads.Cool_Ducts_Sens *= frac_zone_cool_load_served
    hvac_loads.Cool_IntGains_Sens *= frac_zone_cool_load_served
    hvac_loads.Cool_Ducts_Lat *= frac_zone_cool_load_served
    hvac_loads.Cool_Infil_Lat *= frac_zone_cool_load_served
    hvac_loads.Cool_Vent_Lat *= frac_zone_cool_load_served
    hvac_loads.Cool_IntGains_Lat *= frac_zone_cool_load_served
    hvac_loads.Cool_BlowerHeat *= frac_zone_cool_load_served
  end

  # Returns the ACCA Manual S sizing allowances for a given type of HVAC equipment.
  # These sizing allowances are used in the logic that determines how to convert heating/cooling
  # design loads into corresponding equipment capacities.
  #
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @return [Array<Double, Double, Double>] Oversize fraction (frac), oversize delta (Btu/hr), undersize fraction (frac)
  def self.get_hvac_size_limits(hvac_cooling)
    oversize_limit = 1.15
    oversize_delta = 15000.0
    undersize_limit = 0.9

    if not hvac_cooling.nil?
      if hvac_cooling.compressor_type == HPXML::HVACCompressorTypeTwoStage
        oversize_limit = 1.2
      elsif hvac_cooling.compressor_type == HPXML::HVACCompressorTypeVariableSpeed
        oversize_limit = 1.3
      end
    end

    return oversize_limit, oversize_delta, undersize_limit
  end

  # Transfers the design load totals from the HVAC loads object to the HVAC sizings object.
  #
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @return [void]
  def self.apply_hvac_loads_to_hvac_sizings(hvac_sizings, hvac_loads)
    # Note: We subtract the blower heat below because we want to calculate a net capacity,
    # not a gross capacity.
    hvac_sizings.Cool_Load_Sens = hvac_loads.Cool_Sens - hvac_loads.Cool_BlowerHeat
    hvac_sizings.Cool_Load_Lat = hvac_loads.Cool_Lat
    hvac_sizings.Cool_Load_Tot = hvac_loads.Cool_Tot - hvac_loads.Cool_BlowerHeat
    hvac_sizings.Heat_Load = hvac_loads.Heat_Tot
    hvac_sizings.Heat_Load_Supp = hvac_loads.Heat_Tot
  end

  # Updates the design loads for a heat pump to comply with the specified heat pump sizing methodology.
  #
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param frac_zone_heat_load_served [Double] Fraction of zone heating load served by this HVAC system
  # @param frac_zone_cool_load_served [Double] Fraction of zone cooling load served by this HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.apply_hvac_heat_pump_logic(hvac_sizings, hvac_cooling, frac_zone_heat_load_served, frac_zone_cool_load_served, hpxml_bldg)
    # Only apply logic to a heat pump that provides both heating and cooling
    return unless hvac_cooling.is_a? HPXML::HeatPump
    return if hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingACCA
    return if frac_zone_heat_load_served == 0
    return if frac_zone_cool_load_served == 0

    # If HERS/MaxLoad methodology, use at least the larger of heating/cooling loads for heat pump sizing.
    # Note: Heat_Load_Supp should NOT be adjusted; we only want to adjust the HP capacity, not the HP backup heating capacity.
    max_load = [hvac_sizings.Heat_Load, hvac_sizings.Cool_Load_Tot].max
    hvac_sizings.Heat_Load = max_load
    hvac_sizings.Cool_Load_Sens *= max_load / hvac_sizings.Cool_Load_Tot
    hvac_sizings.Cool_Load_Lat *= max_load / hvac_sizings.Cool_Load_Tot
    hvac_sizings.Cool_Load_Tot = max_load
  end

  # Calculates the duct thermal regain factor, which is defined as the fraction of distribution
  # system losses (gains for cooling) that are returned to the conditioned space.
  #
  # Sources: MJ8 pg 204 and Walker (1998) "Technical background for default values used for
  # forced air systems in proposed ASHRAE Std. 152"
  #
  # @param duct [HPXML::Duct] The duct to calculate regain for
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Double] The duct regain factor (frac)
  def self.get_duct_regain_factor(duct, hpxml_bldg)
    f_regain = nil

    if [HPXML::LocationOutside, HPXML::LocationRoofDeck].include? duct.duct_location
      f_regain = 0.0

    elsif [HPXML::LocationOtherHousingUnit, HPXML::LocationOtherHeatedSpace, HPXML::LocationOtherMultifamilyBufferSpace,
           HPXML::LocationOtherNonFreezingSpace, HPXML::LocationExteriorWall, HPXML::LocationUnderSlab,
           HPXML::LocationManufacturedHomeBelly].include? duct.duct_location
      space_values = Geometry.get_temperature_scheduled_space_values(location: duct.duct_location)
      f_regain = space_values[:f_regain]

    elsif [HPXML::LocationBasementUnconditioned, HPXML::LocationCrawlspaceVented, HPXML::LocationCrawlspaceUnvented].include? duct.duct_location

      ceilings = hpxml_bldg.floors.select { |f| f.is_floor && [f.interior_adjacent_to, f.exterior_adjacent_to].include?(duct.duct_location) }
      avg_ceiling_rvalue = calculate_average_r_value(ceilings)
      ceiling_insulated = (avg_ceiling_rvalue > 4)

      walls = hpxml_bldg.foundation_walls.select { |f| [f.interior_adjacent_to, f.exterior_adjacent_to].include? duct.duct_location }
      avg_wall_rvalue = calculate_average_r_value(walls)
      walls_insulated = (avg_wall_rvalue > 4)

      if duct.duct_location == HPXML::LocationBasementUnconditioned
        if not ceiling_insulated
          if not walls_insulated
            f_regain = 0.50 # Uninsulated ceiling, uninsulated walls
          else
            f_regain = 0.75 # Uninsulated ceiling, insulated walls
          end
        else
          f_regain = 0.30 # Insulated ceiling
        end
      elsif duct.duct_location == HPXML::LocationCrawlspaceVented
        if ceiling_insulated && walls_insulated
          f_regain = 0.17 # Insulated ceiling, insulated walls
        elsif ceiling_insulated && (not walls_insulated)
          f_regain = 0.12 # Insulated ceiling, uninsulated walls
        elsif (not ceiling_insulated) && walls_insulated
          f_regain = 0.66 # Uninsulated ceiling, insulated walls
        elsif (not ceiling_insulated) && (not walls_insulated)
          f_regain = 0.50 # Uninsulated ceiling, uninsulated walls
        end
      elsif duct.duct_location == HPXML::LocationCrawlspaceUnvented
        if ceiling_insulated && walls_insulated
          f_regain = 0.30 # Insulated ceiling, insulated walls
        elsif ceiling_insulated && (not walls_insulated)
          f_regain = 0.16 # Insulated ceiling, uninsulated walls
        elsif (not ceiling_insulated) && walls_insulated
          f_regain = 0.76 # Uninsulated ceiling, insulated walls
        elsif (not ceiling_insulated) && (not walls_insulated)
          f_regain = 0.60 # Uninsulated ceiling, uninsulated walls
        end
      end

    elsif [HPXML::LocationAtticVented, HPXML::LocationAtticUnvented].include? duct.duct_location
      f_regain = 0.10 # This would likely be higher for unvented attics with roof insulation

    elsif [HPXML::LocationGarage].include? duct.duct_location
      f_regain = 0.05

    elsif HPXML::conditioned_locations.include? duct.duct_location
      f_regain = 1.0

    end

    return f_regain
  end

  # Applies heating duct loads to the HVAC/zone/space loads as appropriate.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param zone [HPXML::Zone] The current zone of interest
  # @param hvac_loads [DesignLoadValues] Object with design loads for the current HPXML HVAC system
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.apply_hvac_duct_loads_heating(mj, zone, hvac_loads, zone_loads, all_space_loads, hvac_heating, hpxml_bldg)
    return if hvac_heating.nil? || (hvac_loads.Heat_Tot <= 0) || hvac_heating.distribution_system.nil? || hvac_heating.distribution_system.ducts.empty?

    hvac_heating_ap = hvac_heating.additional_properties

    init_heat_load = hvac_loads.Heat_Tot

    # Distribution system efficiency (DSE) calculations based on ASHRAE Standard 152

    duct_values = calc_duct_conduction_values(hvac_heating.distribution_system, mj.heat_design_temps, hpxml_bldg)
    a_s, a_r, rvalue_s, rvalue_r, t_amb_s, t_amb_r, f_regain_s, f_regain_r = duct_values

    # Initialize for the iteration
    delta = 1
    heat_load_next = init_heat_load

    for _iter in 0..19
      break if delta.abs <= 0.001

      heat_load_prev = heat_load_next

      # Calculate the new heating air flow rate
      heating_delta_t = hvac_heating_ap.supply_air_temp - mj.heat_setpoint
      heat_cfm = calc_airflow_rate_manual_s(mj, heat_load_next, heating_delta_t)

      q_s, q_r = calc_duct_leakages_cfm25(hvac_heating.distribution_system, heat_cfm)

      de = calc_delivery_effectiveness_heating(mj, q_s, q_r, heat_cfm, heat_load_next, t_amb_s, t_amb_r, a_s, a_r, mj.heat_setpoint, f_regain_s, f_regain_r, rvalue_s, rvalue_r)

      # Calculate the increase in heating load due to ducts (Approach: DE = Qload/Qequip -> Qducts = Qequip-Qload)
      heat_load_next = init_heat_load / de

      # Calculate the change since the last iteration
      delta = (heat_load_next - heat_load_prev) / heat_load_prev
    end

    ducts_heat_load = heat_load_next - init_heat_load

    hvac_loads.Heat_Ducts += ducts_heat_load
    hvac_loads.Heat_Tot += ducts_heat_load

    # Don't assign HP backup system duct loads to the zone/spaces; we already have the HP
    # duct loads assigned and don't want to double-count.
    return if hvac_heating.is_a?(HPXML::HeatingSystem) && hvac_heating.is_heat_pump_backup_system

    zone_loads.Heat_Ducts += ducts_heat_load
    zone_loads.Heat_Tot += ducts_heat_load

    zone_htg_load = zone.spaces.map { |space| all_space_loads[space].Heat_Tot }.sum
    zone.spaces.each do |space|
      space_loads = all_space_loads[space]
      space_htg_duct_load = ducts_heat_load * space_loads.Heat_Tot / zone_htg_load
      space_loads.Heat_Ducts += space_htg_duct_load
      space_loads.Heat_Tot += space_htg_duct_load
    end
  end

  # Applies cooling duct loads to the HVAC/zone/space loads as appropriate.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param zone [HPXML::Zone] The current zone of interest
  # @param hvac_loads [DesignLoadValues] Object with design loads for the current HPXML HVAC system
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param weather [WeatherFile] Weather object containing EPW information
  # @return [void]
  def self.apply_hvac_duct_loads_cooling(mj, zone, hvac_loads, zone_loads, all_space_loads, hvac_cooling, hpxml_bldg, weather)
    return if hvac_cooling.nil? || (hvac_loads.Cool_Sens <= 0) || hvac_cooling.distribution_system.nil? || hvac_cooling.distribution_system.ducts.empty?

    hvac_cooling_ap = hvac_cooling.additional_properties

    init_cool_load_sens = hvac_loads.Cool_Sens
    init_cool_load_lat = hvac_loads.Cool_Lat

    # Distribution system efficiency (DSE) calculations based on ASHRAE Standard 152

    duct_values = calc_duct_conduction_values(hvac_cooling.distribution_system, mj.cool_design_temps, hpxml_bldg)
    a_s, a_r, rvalue_s, rvalue_r, t_amb_s, t_amb_r, f_regain_s, f_regain_r = duct_values

    # Calculate the air enthalpy in the return duct location for DSE calculations
    h_r = Psychrometrics.h_fT_w(t_amb_r, weather.design.CoolingHumidityRatio)

    # Initialize for the iteration
    delta = 1
    cool_load_tot_next = init_cool_load_sens + init_cool_load_lat

    cooling_delta_t = mj.cool_setpoint - hvac_cooling_ap.leaving_air_temp
    cool_cfm = calc_airflow_rate_manual_s(mj, init_cool_load_sens, cooling_delta_t)
    _q_s, q_r = calc_duct_leakages_cfm25(hvac_cooling.distribution_system, cool_cfm)

    for _iter in 1..50
      break if delta.abs <= 0.001

      cool_load_tot_prev = cool_load_tot_next

      cool_load_lat, cool_load_sens = calculate_sensible_latent_split(mj, q_r, cool_load_tot_next, init_cool_load_lat)
      cool_load_tot = cool_load_lat + cool_load_sens

      # Calculate the new cooling air flow rate
      cool_cfm = calc_airflow_rate_manual_s(mj, cool_load_sens, cooling_delta_t)

      q_s, q_r = calc_duct_leakages_cfm25(hvac_cooling.distribution_system, cool_cfm)

      de = calc_delivery_effectiveness_cooling(mj, q_s, q_r, hvac_cooling_ap.leaving_air_temp, cool_cfm, cool_load_sens, cool_load_tot, t_amb_s, t_amb_r, a_s, a_r, mj.cool_setpoint, f_regain_s, f_regain_r, h_r, rvalue_s, rvalue_r)

      cool_load_tot_next = (init_cool_load_sens + init_cool_load_lat) / de

      # Calculate the change since the last iteration
      delta = (cool_load_tot_next - cool_load_tot_prev) / cool_load_tot_prev
    end

    ducts_cool_load_sens = cool_load_sens - init_cool_load_sens
    ducts_cool_load_lat = cool_load_lat - init_cool_load_lat

    hvac_loads.Cool_Ducts_Sens += ducts_cool_load_sens
    hvac_loads.Cool_Sens += ducts_cool_load_sens
    hvac_loads.Cool_Ducts_Lat += ducts_cool_load_lat
    hvac_loads.Cool_Lat += ducts_cool_load_lat
    hvac_loads.Cool_Tot += ducts_cool_load_sens + ducts_cool_load_lat

    zone_loads.Cool_Ducts_Sens += ducts_cool_load_sens
    zone_loads.Cool_Sens += ducts_cool_load_sens
    zone_loads.Cool_Ducts_Lat += ducts_cool_load_lat
    zone_loads.Cool_Lat += ducts_cool_load_lat
    zone_loads.Cool_Tot += ducts_cool_load_sens + ducts_cool_load_lat

    zone_clg_load_sens = zone.spaces.map { |space| all_space_loads[space].Cool_Sens }.sum
    zone.spaces.each do |space|
      space_loads = all_space_loads[space]
      space_clg_duct_load = ducts_cool_load_sens * space_loads.Cool_Sens / zone_clg_load_sens
      space_loads.Cool_Ducts_Sens += space_clg_duct_load
      space_loads.Cool_Sens += space_clg_duct_load
    end
  end

  # Applies CFIS ventilation loads to the HVAC/zone loads as appropriate. Note that CFIS loads
  # are considered system loads, not space loads like other ventilation systems.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hvac_loads [DesignLoadValues] Object with design loads for the current HPXML HVAC system
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.apply_hvac_cfis_loads(mj, hvac_loads, zone_loads, hvac_heating, hvac_cooling, hpxml_bldg)
    if (not hvac_heating.nil?) && (not hvac_heating.distribution_system.nil?)
      hvac_distribution = hvac_heating.distribution_system
    elsif (not hvac_cooling.nil?) && (not hvac_cooling.distribution_system.nil?)
      hvac_distribution = hvac_cooling.distribution_system
    end
    return if hvac_distribution.nil?

    vent_mech_cfis = hpxml_bldg.ventilation_fans.find { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeCFIS && vent_mech.distribution_system_idref == hvac_distribution.id }
    return if vent_mech_cfis.nil?

    vent_cfm = vent_mech_cfis.average_unit_flow_rate

    heat_load = 1.1 * mj.acf * vent_cfm * mj.htd
    cool_sens_load = 1.1 * mj.acf * vent_cfm * mj.ctd
    cool_lat_load = 0.68 * mj.acf * vent_cfm * mj.cool_design_grains

    hvac_loads.Heat_Vent += heat_load
    hvac_loads.Heat_Tot += heat_load
    hvac_loads.Cool_Vent_Sens += cool_sens_load
    hvac_loads.Cool_Sens += cool_sens_load
    hvac_loads.Cool_Vent_Lat += cool_lat_load
    hvac_loads.Cool_Lat += cool_lat_load
    hvac_loads.Cool_Tot += cool_sens_load + cool_lat_load

    zone_loads.Heat_Vent += heat_load
    zone_loads.Heat_Tot += heat_load
    zone_loads.Cool_Vent_Sens += cool_sens_load
    zone_loads.Cool_Sens += cool_sens_load
    zone_loads.Cool_Vent_Lat += cool_lat_load
    zone_loads.Cool_Lat += cool_lat_load
    zone_loads.Cool_Tot += cool_sens_load + cool_lat_load
  end

  # Applies blower fan heat loads for air distribution systems to the HVAC/zone loads as appropriate.
  #
  # @param hvac_loads [DesignLoadValues] Object with design loads for the current HPXML HVAC system
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @return [void]
  def self.apply_hvac_blower_heat_load(hvac_loads, zone_loads, hvac_heating, hvac_cooling)
    if not hvac_heating.nil?
      hvac_distribution = hvac_heating.distribution_system
    elsif not hvac_cooling.nil?
      hvac_distribution = hvac_cooling.distribution_system
    end
    return if hvac_distribution.nil?
    return if hvac_distribution.distribution_system_type != HPXML::HVACDistributionTypeAir

    cool_load = hvac_distribution.manualj_blower_fan_heat_btuh

    hvac_loads.Cool_BlowerHeat += cool_load
    hvac_loads.Cool_Sens += cool_load
    hvac_loads.Cool_Tot += cool_load

    zone_loads.Cool_BlowerHeat += cool_load
    zone_loads.Cool_Sens += cool_load
    zone_loads.Cool_Tot += cool_load
  end

  # Applies hot water piping loads for hydronic distribution systems to the HVAC/zone loads as appropriate.
  #
  # @param hvac_loads [DesignLoadValues] Object with design loads for the current HPXML HVAC system
  # @param zone_loads [DesignLoadValues] Object with design loads for the current HPXML::Zone
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @return [void]
  def self.apply_hvac_piping_load(hvac_loads, zone_loads, hvac_heating)
    if not hvac_heating.nil?
      hvac_distribution = hvac_heating.distribution_system
    end
    return if hvac_distribution.nil?
    return if hvac_distribution.distribution_system_type != HPXML::HVACDistributionTypeHydronic

    heat_load = hvac_distribution.manualj_hot_water_piping_btuh

    hvac_loads.Heat_Piping += heat_load
    hvac_loads.Heat_Tot += heat_load

    zone_loads.Heat_Piping += heat_load
    zone_loads.Heat_Tot += heat_load
  end

  # Equipment Adjustments
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param hvac_system [Hash] HPXML HVAC (heating and/or cooling) system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.apply_hvac_equipment_adjustments(mj, runner, hvac_sizings, weather, hvac_heating, hvac_cooling, hvac_system, hpxml_bldg)
    # Cooling

    cooling_type = get_hvac_cooling_type(hvac_cooling)

    if not cooling_type.nil?
      hvac_cooling_ap = hvac_cooling.additional_properties
      is_ducted = !hvac_cooling.distribution_system.nil?
      cooling_delta_t = mj.cool_setpoint - hvac_cooling_ap.leaving_air_temp
      oversize_limit, oversize_delta, undersize_limit = get_hvac_size_limits(hvac_cooling)
    end

    if hvac_sizings.Cool_Load_Tot <= 0

      hvac_sizings.Cool_Capacity = 0.0
      hvac_sizings.Cool_Capacity_Sens = 0.0
      hvac_sizings.Cool_Airflow = 0.0

    elsif [HPXML::HVACTypeCentralAirConditioner,
           HPXML::HVACTypeHeatPumpAirToAir].include?(cooling_type) ||
          ([HPXML::HVACTypeMiniSplitAirConditioner,
            HPXML::HVACTypeHeatPumpMiniSplit].include?(cooling_type) && is_ducted)
      # For central systems, the installer can take steps to try to meet both sensible and latent loads,
      # such as different indoor/outdoor coil combinations and different blower settings.
      # Ductless systems don't offer this flexibility.

      entering_temp = hpxml_bldg.header.manualj_cooling_design_temp
      hvac_cooling_speed = get_nominal_speed(hvac_cooling_ap, true)
      if hvac_cooling.compressor_type == HPXML::HVACCompressorTypeVariableSpeed
        idb_adj = adjust_indoor_condition_var_speed(entering_temp, mj.cool_indoor_wetbulb, :clg)
        odb_adj = adjust_outdoor_condition_var_speed(entering_temp, hvac_cooling, :clg)
        total_cap_curve_value = odb_adj * idb_adj
      else
        coefficients = hvac_cooling_ap.cool_cap_ft_spec[hvac_cooling_speed]
        total_cap_curve_value = MathTools.biquadratic(mj.cool_indoor_wetbulb, entering_temp, coefficients)
      end

      cool_cap_rated = hvac_sizings.Cool_Load_Tot / total_cap_curve_value

      hvac_cooling_shr = hvac_cooling_ap.cool_rated_shrs_gross[hvac_cooling_speed]
      sens_cap_rated = cool_cap_rated * hvac_cooling_shr

      # Calculate the air flow rate required for design conditions
      hvac_sizings.Cool_Airflow = calc_airflow_rate_manual_s(mj, hvac_sizings.Cool_Load_Sens, cooling_delta_t, dx_capacity: cool_cap_rated)

      sensible_cap_curve_value = process_curve_fit(hvac_sizings.Cool_Airflow, hvac_sizings.Cool_Load_Tot, entering_temp)
      sens_cap_design = sens_cap_rated * sensible_cap_curve_value
      lat_cap_design = [hvac_sizings.Cool_Load_Tot - sens_cap_design, 1.0].max

      shr_biquadratic = get_shr_biquadratic
      a_sens = shr_biquadratic[0]
      b_sens = shr_biquadratic[1]
      c_sens = shr_biquadratic[3]
      d_sens = shr_biquadratic[5]

      # Adjust Sizing
      if hvac_cooling.is_a?(HPXML::HeatPump) && (hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingHERS)
        hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr

        cool_load_sens_cap_design = hvac_sizings.Cool_Capacity_Sens * sensible_cap_curve_value

      elsif lat_cap_design < hvac_sizings.Cool_Load_Lat
        # Size by MJ8 Latent load, return to rated conditions

        # Solve for the new sensible and total capacity at design conditions:
        # CoolingLoad_Lat = cool_cap_design - cool_load_sens_cap_design
        # solve the following for cool_cap_design: sens_cap_design = SHRRated * cool_cap_design / total_cap_curve_value * function(CFM/cool_cap_design, ODB)
        # substituting in CFM = cool_load_sens_cap_design / (1.1 * ACF * (cool_setpoint - LAT))

        cool_load_sens_cap_design = hvac_sizings.Cool_Load_Lat / ((total_cap_curve_value / hvac_cooling_shr - \
                                  (b_sens + d_sens * entering_temp) / \
                                  (1.1 * mj.acf * cooling_delta_t)) / \
                                  (a_sens + c_sens * entering_temp) - 1.0)

        # Ensure equipment is not being undersized
        cool_load_sens_cap_design = [cool_load_sens_cap_design, undersize_limit * hvac_sizings.Cool_Load_Sens].max

        cool_cap_design = cool_load_sens_cap_design + hvac_sizings.Cool_Load_Lat

        # The SHR of the equipment at the design condition
        shr_design = cool_load_sens_cap_design / cool_cap_design

        # If the adjusted equipment size is negative (occurs at altitude), use oversize limit (the adjustment
        # almost always hits the oversize limit in this case, making this a safe assumption)
        if (cool_cap_design < 0) || (cool_load_sens_cap_design < 0)
          cool_cap_design = oversize_limit * hvac_sizings.Cool_Load_Tot
        end

        # Limit total capacity to oversize limit
        cool_cap_design = [cool_cap_design, oversize_limit * hvac_sizings.Cool_Load_Tot].min

        # Determine rated capacities
        hvac_sizings.Cool_Capacity = cool_cap_design / total_cap_curve_value
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr

        # Determine the final sensible capacity at design using the SHR
        cool_load_sens_cap_design = shr_design * cool_cap_design

      elsif sens_cap_design < undersize_limit * hvac_sizings.Cool_Load_Sens
        # Size by MJ8 Sensible load, return to rated conditions, find Sens with SHRRated. Limit total
        # capacity to oversizing limit

        sens_cap_design = undersize_limit * hvac_sizings.Cool_Load_Sens

        # Solve for the new total system capacity at design conditions:
        # sens_cap_design   = sens_cap_rated * sensible_cap_curve_value
        #                  = SHRRated * cool_cap_design / total_cap_curve_value * sensible_cap_curve_value
        #                  = SHRRated * cool_cap_design / total_cap_curve_value * function(CFM/cool_cap_design, ODB)

        cool_cap_design = (sens_cap_design / (hvac_cooling_shr / total_cap_curve_value) - \
                                           (b_sens * UnitConversions.convert(hvac_sizings.Cool_Airflow, 'ton', 'Btu/hr') + \
                                           d_sens * UnitConversions.convert(hvac_sizings.Cool_Airflow, 'ton', 'Btu/hr') * entering_temp)) / \
                          (a_sens + c_sens * entering_temp)

        # Limit total capacity to oversize limit
        cool_cap_design = [cool_cap_design, oversize_limit * hvac_sizings.Cool_Load_Tot].min

        hvac_sizings.Cool_Capacity = cool_cap_design / total_cap_curve_value
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr

        # Recalculate the air flow rate in case the oversizing limit has been used
        cool_load_sens_cap_design = hvac_sizings.Cool_Capacity_Sens * sensible_cap_curve_value

      else
        hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot / total_cap_curve_value
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr

        cool_load_sens_cap_design = hvac_sizings.Cool_Capacity_Sens * sensible_cap_curve_value
      end

      # Calculate the final air flow rate using final sensible capacity at design
      hvac_sizings.Cool_Airflow = calc_airflow_rate_manual_s(mj, cool_load_sens_cap_design, cooling_delta_t, dx_capacity: hvac_sizings.Cool_Capacity)

    elsif [HPXML::HVACTypeHeatPumpMiniSplit,
           HPXML::HVACTypeMiniSplitAirConditioner].include?(cooling_type) && !is_ducted

      hvac_cooling_speed = get_nominal_speed(hvac_cooling_ap, true)
      hvac_cooling_shr = hvac_cooling_ap.cool_rated_shrs_gross[hvac_cooling_speed]

      if hvac_cooling.is_a?(HPXML::HeatPump) && (hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingHERS)
        hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr
      else
        entering_temp = hpxml_bldg.header.manualj_cooling_design_temp
        idb_adj = adjust_indoor_condition_var_speed(entering_temp, mj.cool_indoor_wetbulb, :clg)
        odb_adj = adjust_outdoor_condition_var_speed(entering_temp, hvac_cooling, :clg)
        total_cap_curve_value = odb_adj * idb_adj

        hvac_sizings.Cool_Capacity = (hvac_sizings.Cool_Load_Tot / total_cap_curve_value)
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr
      end

      hvac_sizings.Cool_Airflow = calc_airflow_rate_user(hvac_sizings.Cool_Capacity, hvac_cooling_ap.cool_rated_cfm_per_ton[hvac_cooling_speed])

    elsif [HPXML::HVACTypeRoomAirConditioner,
           HPXML::HVACTypePTAC,
           HPXML::HVACTypeHeatPumpPTHP,
           HPXML::HVACTypeHeatPumpRoom].include? cooling_type

      hvac_cooling_speed = get_nominal_speed(hvac_cooling_ap, true)
      hvac_cooling_shr = hvac_cooling_ap.cool_rated_shrs_gross[hvac_cooling_speed]

      if hvac_cooling.is_a?(HPXML::HeatPump) && (hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingHERS)
        hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr
      else
        entering_temp = hpxml_bldg.header.manualj_cooling_design_temp
        total_cap_curve_value = MathTools.biquadratic(mj.cool_indoor_wetbulb, entering_temp, hvac_cooling_ap.cool_cap_ft_spec[hvac_cooling_speed])

        hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot / total_cap_curve_value
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr
      end

      hvac_sizings.Cool_Airflow = calc_airflow_rate_user(hvac_sizings.Cool_Capacity, hvac_cooling_ap.cool_rated_cfm_per_ton[0])

    elsif HPXML::HVACTypeHeatPumpGroundToAir == cooling_type

      entering_temp = hvac_cooling_ap.design_chw
      hvac_cooling_speed = get_nominal_speed(hvac_cooling_ap, true)

      gshp_coil_bf = 0.0806
      gshp_coil_bf_ft_spec = [1.21005458, -0.00664200, 0.00000000, 0.00348246, 0.00000000, 0.00000000]

      # Calculate an initial air flow rate assuming 400 cfm/ton
      hvac_sizings.Cool_Airflow = 400.0 * UnitConversions.convert(hvac_sizings.Cool_Load_Sens, 'Btu/hr', 'ton')

      cool_cap_curve_spec = hvac_cooling_ap.cool_cap_curve_spec[hvac_cooling_speed]
      cool_sh_curve_spec = hvac_cooling_ap.cool_sh_curve_spec[hvac_cooling_speed]
      total_cap_curve_value, sensible_cap_curve_value = calc_gshp_clg_curve_value(cool_cap_curve_spec, cool_sh_curve_spec, mj.cool_indoor_wetbulb, mj.cool_setpoint, entering_temp, hvac_sizings.Cool_Airflow)

      bypass_factor_curve_value = MathTools.biquadratic(mj.cool_indoor_wetbulb, mj.cool_setpoint, gshp_coil_bf_ft_spec)
      hvac_cooling_shr = hvac_cooling_ap.cool_rated_shrs_gross[hvac_cooling_speed]

      if hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingHERS
        hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr
      else
        hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot / total_cap_curve_value # Note: cool_cap_design = hvac_sizings.Cool_Load_Tot
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr

        cool_load_sens_cap_design = (hvac_sizings.Cool_Capacity_Sens * sensible_cap_curve_value /
                                   (1.0 + (1.0 - gshp_coil_bf * bypass_factor_curve_value) *
                                   (80.0 - mj.cool_setpoint) / cooling_delta_t))
        cool_load_lat_cap_design = hvac_sizings.Cool_Load_Tot - cool_load_sens_cap_design

        # Adjust Sizing so that coil sensible at design >= CoolingLoad_Sens, and coil latent at design >= CoolingLoad_Lat, and equipment SHRRated is maintained.
        cool_load_sens_cap_design = [cool_load_sens_cap_design, hvac_sizings.Cool_Load_Sens].max
        cool_load_lat_cap_design = [cool_load_lat_cap_design, hvac_sizings.Cool_Load_Lat].max
        cool_cap_design = cool_load_sens_cap_design + cool_load_lat_cap_design

        # Limit total capacity via oversizing limit
        cool_cap_design = [cool_cap_design, oversize_limit * hvac_sizings.Cool_Load_Tot].min
        hvac_sizings.Cool_Capacity = cool_cap_design / total_cap_curve_value
        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr
      end

      # Recalculate the air flow rate in case the oversizing limit has been used
      cool_load_sens_cap_design = (hvac_sizings.Cool_Capacity_Sens * sensible_cap_curve_value /
                                 (1.0 + (1.0 - gshp_coil_bf * bypass_factor_curve_value) *
                                 (80.0 - mj.cool_setpoint) / cooling_delta_t))
      hvac_sizings.Cool_Airflow = calc_airflow_rate_manual_s(mj, cool_load_sens_cap_design, cooling_delta_t, dx_capacity: hvac_sizings.Cool_Capacity)

    elsif HPXML::HVACTypeEvaporativeCooler == cooling_type

      hvac_sizings.Cool_Capacity = hvac_sizings.Cool_Load_Tot
      hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Load_Sens
      if cooling_delta_t > 0
        # See Manual S Section 4-4 Direct Evaporative Cooling: Blower Cfm
        hvac_sizings.Cool_Airflow = calc_airflow_rate_manual_s(mj, hvac_sizings.Cool_Load_Sens, cooling_delta_t)
      else
        hvac_sizings.Cool_Airflow = hpxml_bldg.building_construction.conditioned_floor_area * 2.0 # Use industry rule of thumb sizing method adopted by HEScore
      end

    elsif HPXML::HVACTypeHeatPumpWaterLoopToAir == cooling_type

      # Model only currently used for heating
      hvac_sizings.Cool_Capacity = 0.0
      hvac_sizings.Cool_Capacity_Sens = 0.0
      hvac_sizings.Cool_Airflow = 0.0

    elsif cooling_type.nil?

      hvac_sizings.Cool_Capacity = 0.0
      hvac_sizings.Cool_Capacity_Sens = 0.0
      hvac_sizings.Cool_Airflow = 0.0

    else

      fail "Unexpected cooling type: #{cooling_type}."

    end

    # Heating

    heating_type = get_hvac_heating_type(hvac_heating)

    if not heating_type.nil?
      hvac_heating_ap = hvac_heating.additional_properties
      is_ducted = !hvac_heating.distribution_system.nil?
      heating_delta_t = hvac_heating_ap.supply_air_temp - mj.heat_setpoint

      if hvac_heating.is_a?(HPXML::HeatingSystem) && hvac_heating.is_heat_pump_backup_system
        # Adjust heating load using the HP backup calculation
        hvac_hp = hvac_heating.primary_heat_pump
        hp_sizing_values = @all_hvac_sizings[{ heating: hvac_hp, cooling: hvac_hp }]
        if hp_sizing_values.nil?
          fail 'Primary heat pump should have been sized already.'
        end

        hp_heating_speed = get_nominal_speed(hvac_hp.additional_properties, false)
        hvac_sizings.Heat_Load = calculate_heat_pump_backup_load(mj, hvac_hp, hvac_sizings.Heat_Load, hp_sizing_values.Heat_Capacity, hp_heating_speed, hpxml_bldg)
      end
    elsif not hvac_cooling.nil? && hvac_cooling.has_integrated_heating
      heating_delta_t = hvac_cooling_ap.supply_air_temp - mj.heat_setpoint
    end

    if hvac_sizings.Heat_Load <= 0

      hvac_sizings.Heat_Capacity = 0.0
      hvac_sizings.Heat_Capacity_Supp = 0.0
      hvac_sizings.Heat_Airflow = 0.0

    elsif [HPXML::HVACTypeHeatPumpAirToAir,
           HPXML::HVACTypeHeatPumpMiniSplit,
           HPXML::HVACTypeHeatPumpPTHP,
           HPXML::HVACTypeHeatPumpRoom].include? heating_type

      hvac_heating_speed = get_nominal_speed(hvac_heating_ap, false)
      if hvac_heating.is_a?(HPXML::HeatPump) && (hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingHERS)
        hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
      else
        process_heat_pump_adjustment(mj, runner, hvac_sizings, weather, hvac_heating, total_cap_curve_value, hvac_system, hvac_heating_speed, oversize_limit, oversize_delta, hpxml_bldg)
      end

      hvac_sizings.Heat_Capacity_Supp = calculate_heat_pump_backup_load(mj, hvac_heating, hvac_sizings.Heat_Load_Supp, hvac_sizings.Heat_Capacity, hvac_heating_speed, hpxml_bldg)
      if (heating_type == HPXML::HVACTypeHeatPumpAirToAir) || (heating_type == HPXML::HVACTypeHeatPumpMiniSplit && is_ducted)
        hvac_sizings.Heat_Airflow = calc_airflow_rate_manual_s(mj, hvac_sizings.Heat_Capacity, heating_delta_t, dx_capacity: hvac_sizings.Heat_Capacity, hp_cooling_cfm: hvac_sizings.Cool_Airflow)
      else
        hvac_sizings.Heat_Airflow = calc_airflow_rate_user(hvac_sizings.Heat_Capacity, hvac_heating_ap.heat_rated_cfm_per_ton[hvac_heating_speed])
      end

    elsif [HPXML::HVACTypeHeatPumpGroundToAir].include? heating_type

      if hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingHERS
        hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
        hvac_sizings.Heat_Capacity_Supp = hvac_sizings.Heat_Load_Supp
      elsif hvac_sizings.Cool_Capacity > 0
        hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
        hvac_sizings.Heat_Capacity_Supp = hvac_sizings.Heat_Load_Supp

        # For single stage compressor, when heating capacity is much larger than cooling capacity,
        # in order to avoid frequent cycling in cooling mode, heating capacity is derated to 75%.
        if hvac_sizings.Heat_Capacity >= 1.5 * hvac_sizings.Cool_Capacity
          hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load * 0.75
        end

        hvac_sizings.Cool_Capacity = [hvac_sizings.Cool_Capacity, hvac_sizings.Heat_Capacity].max
        hvac_sizings.Heat_Capacity = hvac_sizings.Cool_Capacity

        hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_shr
        cool_load_sens_cap_design = (hvac_sizings.Cool_Capacity_Sens * sensible_cap_curve_value /
                                   (1.0 + (1.0 - gshp_coil_bf * bypass_factor_curve_value) *
                                   (80.0 - mj.cool_setpoint) / cooling_delta_t))
        hvac_sizings.Cool_Airflow = calc_airflow_rate_manual_s(mj, cool_load_sens_cap_design, cooling_delta_t, dx_capacity: hvac_sizings.Cool_Capacity)
      else
        hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
        hvac_sizings.Heat_Capacity_Supp = hvac_sizings.Heat_Load_Supp
      end
      hvac_sizings.Heat_Airflow = calc_airflow_rate_manual_s(mj, hvac_sizings.Heat_Capacity, heating_delta_t, dx_capacity: hvac_sizings.Heat_Capacity, hp_cooling_cfm: hvac_sizings.Cool_Airflow)

    elsif [HPXML::HVACTypeHeatPumpWaterLoopToAir].include? heating_type

      hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
      hvac_sizings.Heat_Capacity_Supp = hvac_sizings.Heat_Load_Supp

      hvac_sizings.Heat_Airflow = calc_airflow_rate_manual_s(mj, hvac_sizings.Heat_Capacity, heating_delta_t, dx_capacity: hvac_sizings.Heat_Capacity)

    elsif (heating_type == HPXML::HVACTypeFurnace) || ((not hvac_cooling.nil?) && hvac_cooling.has_integrated_heating)

      hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
      hvac_sizings.Heat_Capacity_Supp = 0.0

      hvac_sizings.Heat_Airflow = calc_airflow_rate_manual_s(mj, hvac_sizings.Heat_Capacity, heating_delta_t)

    elsif [HPXML::HVACTypeStove,
           HPXML::HVACTypeSpaceHeater,
           HPXML::HVACTypeWallFurnace,
           HPXML::HVACTypeFloorFurnace,
           HPXML::HVACTypeFireplace].include? heating_type

      hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
      hvac_sizings.Heat_Capacity_Supp = 0.0

      if hvac_heating_ap.heat_rated_cfm_per_ton[0] > 0
        # Fixed airflow rate
        hvac_sizings.Heat_Airflow = UnitConversions.convert(hvac_sizings.Heat_Capacity, 'Btu/hr', 'ton') * hvac_heating_ap.heat_rated_cfm_per_ton[0]
      else
        # Autosized airflow rate
        hvac_sizings.Heat_Airflow = calc_airflow_rate_manual_s(mj, hvac_sizings.Heat_Capacity, heating_delta_t)
      end

    elsif [HPXML::HVACTypeBoiler,
           HPXML::HVACTypeElectricResistance].include? heating_type

      hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
      hvac_sizings.Heat_Capacity_Supp = 0.0
      hvac_sizings.Heat_Airflow = 0.0

    elsif heating_type.nil?

      hvac_sizings.Heat_Capacity = 0.0
      hvac_sizings.Heat_Capacity_Supp = 0.0
      hvac_sizings.Heat_Airflow = 0.0

    else

      fail "Unexpected heating type: #{heating_type}."

    end
  end

  # Calculates the heat pump's heating or cooling capacity at the specified indoor temperature, as a fraction
  # of the heat pump's nominal heating or cooling capacity.
  #
  # @param outdoor_temp [Double] Outdoor drybulb temperature (F)
  # @param indoor_temp [Double] Indoor drybulb (heating) or wetbulb (cooling) temperature (F)
  # @param mode [Symbol] Heating or cooling
  # @return [Double] Heat pump adjustment factor (capacity fraction)
  def self.adjust_indoor_condition_var_speed(outdoor_temp, indoor_temp, mode)
    if mode == :clg
      rated_indoor_temp = HVAC::AirSourceCoolRatedIWB
      coefficients_1speed = HVAC.get_cool_cap_eir_ft_spec(HPXML::HVACCompressorTypeSingleStage)[0][0]
    elsif mode == :htg
      rated_indoor_temp = HVAC::AirSourceHeatRatedIDB
      capacity_retention_temp_1speed, capacity_retention_fraction_1speed = HVAC.get_default_heating_capacity_retention(HPXML::HVACCompressorTypeSingleStage)
      coefficients_1speed = HVAC.get_heat_cap_eir_ft_spec(HPXML::HVACCompressorTypeSingleStage, capacity_retention_temp_1speed, capacity_retention_fraction_1speed)[0][0]
    end
    return MathTools.biquadratic(indoor_temp, outdoor_temp, coefficients_1speed) / MathTools.biquadratic(rated_indoor_temp, outdoor_temp, coefficients_1speed)
  end

  # Calculates the heat pump's heating or cooling capacity at the specified outdoor temperature, as a fraction
  # of the heat pump's nominal heating or cooling capacity.
  #
  # @param outdoor_temp [Double] Outdoor drybulb temperature (F)
  # @param hvac_sys [HPXML::CoolingSystem or HPXML::HeatPump] HPXML HVAC system of interest
  # @param mode [Symbol] Heating or cooling
  # @return [Double] Heat pump adjustment factor (capacity fraction)
  def self.adjust_outdoor_condition_var_speed(outdoor_temp, hvac_sys, mode)
    rated_odb = (mode == :clg) ? HVAC::AirSourceCoolRatedODB : HVAC::AirSourceHeatRatedODB
    detailed_performance_data = (mode == :clg) ? hvac_sys.cooling_detailed_performance_data : hvac_sys.heating_detailed_performance_data
    if detailed_performance_data.empty?
      # Based on retention fraction and retention temperature
      if mode == :clg
        capacity_retention_temperature = hvac_sys.additional_properties.cooling_capacity_retention_temperature
        capacity_retention_fraction = hvac_sys.additional_properties.cooling_capacity_retention_fraction
      elsif mode == :htg
        capacity_retention_temperature, capacity_retention_fraction = HVAC.get_heating_capacity_retention(hvac_sys)
      end
      odb_adj = (1.0 - capacity_retention_fraction) / (rated_odb - capacity_retention_temperature) * (outdoor_temp - rated_odb) + 1.0
    else # there are detailed performance data
      # Based on detailed performance data
      max_rated_dp = detailed_performance_data.find { |dp| dp.outdoor_temperature == rated_odb && dp.capacity_description == HPXML::CapacityDescriptionMaximum }
      if max_rated_dp.capacity.nil?
        property = :capacity_fraction_of_nominal
      else
        property = :capacity
      end
      capacity_max = detailed_performance_data.find { |dp| dp.outdoor_temperature == rated_odb && dp.capacity_description == HPXML::CapacityDescriptionMaximum }.send(property)
      odb_adj = HVAC.interpolate_to_odb_table_point(detailed_performance_data, HPXML::CapacityDescriptionMaximum, outdoor_temp, property) / capacity_max
    end
    return odb_adj
  end

  # Increases the autosized heating/cooling capacities to account for any reduction in
  # capacity due to HVAC installation quality. This is done to prevent unmet hours.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param frac_zone_heat_load_served [Double] Fraction of zone heating load served by this HVAC system
  # @param frac_zone_cool_load_served [Double] Fraction of zone cooling load served by this HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.apply_hvac_installation_quality(mj, hvac_sizings, hvac_heating, hvac_cooling, frac_zone_heat_load_served, frac_zone_cool_load_served, hpxml_bldg)
    cool_charge_defect_ratio = 0.0
    cool_airflow_defect_ratio = 0.0
    heat_airflow_defect_ratio = 0.0

    if not hvac_cooling.nil?
      if hvac_cooling.respond_to? :charge_defect_ratio
        cool_charge_defect_ratio = hvac_cooling.charge_defect_ratio.to_f
      end
      if hvac_cooling.respond_to? :airflow_defect_ratio
        cool_airflow_defect_ratio = hvac_cooling.airflow_defect_ratio.to_f
      end
    end
    if (not hvac_heating.nil?)
      if hvac_heating.respond_to? :airflow_defect_ratio
        heat_airflow_defect_ratio = hvac_heating.airflow_defect_ratio.to_f
      end
    end

    return if (cool_charge_defect_ratio.abs < 0.001) && (cool_airflow_defect_ratio.abs < 0.001) && (heat_airflow_defect_ratio.abs < 0.001)

    # Cooling

    cooling_type = get_hvac_cooling_type(hvac_cooling)
    f_ch = cool_charge_defect_ratio.round(3)

    if [HPXML::HVACTypeHeatPumpAirToAir,
        HPXML::HVACTypeCentralAirConditioner,
        HPXML::HVACTypeHeatPumpMiniSplit,
        HPXML::HVACTypeMiniSplitAirConditioner,
        HPXML::HVACTypeHeatPumpGroundToAir].include?(cooling_type) && frac_zone_cool_load_served > 0

      hvac_cooling_ap = hvac_cooling.additional_properties
      hvac_cooling_speed = get_nominal_speed(hvac_cooling_ap, true)

      if cooling_type != HPXML::HVACTypeHeatPumpGroundToAir
        cool_cfm_m3s = UnitConversions.convert(hvac_sizings.Cool_Airflow, 'cfm', 'm^3/s')
        cool_airflow_rated_ratio = cool_cfm_m3s / HVAC.calc_rated_airflow(hvac_sizings.Cool_Capacity, hvac_cooling_ap.cool_rated_cfm_per_ton[hvac_cooling_speed])
        cool_airflow_rated_defect_ratio = cool_cfm_m3s * (1 + cool_airflow_defect_ratio) / HVAC.calc_rated_airflow(hvac_sizings.Cool_Capacity, hvac_cooling_ap.cool_rated_cfm_per_ton[hvac_cooling_speed])
      else
        cool_airflow_rated_ratio = 1.0 # actual air flow is equal to rated (before applying defect ratio) in current methodology
        cool_airflow_rated_defect_ratio = 1 + cool_airflow_defect_ratio
      end

      # NOTE: heat pump (cooling) curves don't exhibit expected trends at extreme faults;
      clg_fff_cap_coeff, _clg_fff_eir_coeff = HVAC.get_cool_cap_eir_fflow_spec(HPXML::HVACCompressorTypeSingleStage)[0]
      a1_AF_Qgr_c = clg_fff_cap_coeff[0]
      a2_AF_Qgr_c = clg_fff_cap_coeff[1]
      a3_AF_Qgr_c = clg_fff_cap_coeff[2]

      qgr_values, _p_values, ff_chg_values = HVAC.get_charge_fault_cooling_coeff(f_ch)

      a1_CH_Qgr_c = qgr_values[0]
      a2_CH_Qgr_c = qgr_values[1]
      a3_CH_Qgr_c = qgr_values[2]
      a4_CH_Qgr_c = qgr_values[3]

      q0_CH = a1_CH_Qgr_c
      q1_CH = a2_CH_Qgr_c * UnitConversions.convert(mj.cool_setpoint, 'F', 'C')
      q2_CH = a3_CH_Qgr_c * UnitConversions.convert(hpxml_bldg.header.manualj_cooling_design_temp, 'F', 'C')
      q3_CH = a4_CH_Qgr_c * f_ch
      y_CH_Q_c = 1 + ((q0_CH + q1_CH + q2_CH + q3_CH) * f_ch)

      ff_ch_c = (1.0 / (1.0 + (qgr_values[0] + (qgr_values[1] * ff_chg_values[0]) + (qgr_values[2] * ff_chg_values[1]) + (qgr_values[3] * f_ch)) * f_ch)).round(3)
      ff_AF_c = cool_airflow_rated_defect_ratio.round(3)
      ff_AF_comb_c = ff_ch_c * ff_AF_c

      q_AF_CH = a1_AF_Qgr_c + (a2_AF_Qgr_c * ff_ch_c) + (a3_AF_Qgr_c * ff_ch_c * ff_ch_c)
      p_CH_Q_c = y_CH_Q_c / q_AF_CH

      p_AF_Q_c = a1_AF_Qgr_c + (a2_AF_Qgr_c * ff_AF_comb_c) + (a3_AF_Qgr_c * ff_AF_comb_c * ff_AF_comb_c)

      cool_cap_fff = (p_CH_Q_c * p_AF_Q_c)

      # calculate the capacity impact by defects
      ff_AF_c_nodefect = cool_airflow_rated_ratio.round(3)
      cool_cap_fff_nodefect = a1_AF_Qgr_c + a2_AF_Qgr_c * ff_AF_c_nodefect + a3_AF_Qgr_c * ff_AF_c_nodefect * ff_AF_c_nodefect
      cap_clg_ratio = 1 / (cool_cap_fff / cool_cap_fff_nodefect)

      prev_capacity = hvac_sizings.Cool_Capacity
      hvac_sizings.Cool_Capacity *= cap_clg_ratio
      hvac_sizings.Cool_Capacity_Sens = hvac_sizings.Cool_Capacity * hvac_cooling_ap.cool_rated_shrs_gross[hvac_cooling_speed]
      if prev_capacity > 0 # Preserve cfm/ton
        hvac_sizings.Cool_Airflow = hvac_sizings.Cool_Airflow * hvac_sizings.Cool_Capacity / prev_capacity
      else
        hvac_sizings.Cool_Airflow = 0.0
      end
    end

    # Heating

    heating_type = get_hvac_heating_type(hvac_heating)

    if [HPXML::HVACTypeHeatPumpAirToAir,
        HPXML::HVACTypeHeatPumpMiniSplit,
        HPXML::HVACTypeHeatPumpGroundToAir].include?(heating_type) && frac_zone_heat_load_served > 0

      hvac_heating_ap = hvac_heating.additional_properties
      hvac_heating_speed = get_nominal_speed(hvac_heating_ap, false)

      if heating_type != HPXML::HVACTypeHeatPumpGroundToAir
        heat_cfm_m3s = UnitConversions.convert(hvac_sizings.Heat_Airflow, 'cfm', 'm^3/s')
        heat_airflow_rated_ratio = heat_cfm_m3s / HVAC.calc_rated_airflow(hvac_sizings.Heat_Capacity, hvac_heating_ap.heat_rated_cfm_per_ton[hvac_heating_speed])
        heat_airflow_rated_defect_ratio = heat_cfm_m3s * (1 + heat_airflow_defect_ratio) / HVAC.calc_rated_airflow(hvac_sizings.Heat_Capacity, hvac_heating_ap.heat_rated_cfm_per_ton[hvac_heating_speed])
      else
        heat_airflow_rated_ratio = 1.0 # actual air flow is equal to rated (before applying defect ratio) in current methodology
        heat_airflow_rated_defect_ratio = 1 + heat_airflow_defect_ratio
      end

      htg_fff_cap_coeff, _htg_fff_eir_coeff = HVAC.get_heat_cap_eir_fflow_spec(HPXML::HVACCompressorTypeSingleStage)[0]
      a1_AF_Qgr_h = htg_fff_cap_coeff[0]
      a2_AF_Qgr_h = htg_fff_cap_coeff[1]
      a3_AF_Qgr_h = htg_fff_cap_coeff[2]

      qgr_values, _p_values, ff_chg_values = HVAC.get_charge_fault_heating_coeff(f_ch)

      a1_CH_Qgr_h = qgr_values[0]
      a2_CH_Qgr_h = qgr_values[2]
      a3_CH_Qgr_h = qgr_values[3]

      qh1_CH = a1_CH_Qgr_h
      qh2_CH = a2_CH_Qgr_h * UnitConversions.convert(hpxml_bldg.header.manualj_heating_design_temp, 'F', 'C')
      qh3_CH = a3_CH_Qgr_h * f_ch
      y_CH_Q_h = 1 + ((qh1_CH + qh2_CH + qh3_CH) * f_ch)

      ff_ch_h = (1 / (1 + (qgr_values[0] + qgr_values[2] * ff_chg_values[1] + qgr_values[3] * f_ch) * f_ch)).round(3)
      ff_AF_h = heat_airflow_rated_defect_ratio.round(3)
      ff_AF_comb_h = ff_ch_h * ff_AF_h

      qh_AF_CH = a1_AF_Qgr_h + (a2_AF_Qgr_h * ff_ch_h) + (a3_AF_Qgr_h * ff_ch_h * ff_ch_h)
      p_CH_Q_h = y_CH_Q_h / qh_AF_CH

      p_AF_Q_h = a1_AF_Qgr_h + (a2_AF_Qgr_h * ff_AF_comb_h) + (a3_AF_Qgr_h * ff_AF_comb_h * ff_AF_comb_h)

      heat_cap_fff = (p_CH_Q_h * p_AF_Q_h)

      # calculate the capacity impact by defects
      ff_AF_h_nodefect = heat_airflow_rated_ratio.round(3)
      heat_cap_fff_nodefect = a1_AF_Qgr_h + a2_AF_Qgr_h * ff_AF_h_nodefect + a3_AF_Qgr_h * ff_AF_h_nodefect * ff_AF_h_nodefect
      cap_htg_ratio = 1 / (heat_cap_fff / heat_cap_fff_nodefect)

      prev_capacity = hvac_sizings.Heat_Capacity
      hvac_sizings.Heat_Capacity *= cap_htg_ratio
      if prev_capacity > 0 # Preserve cfm/ton
        hvac_sizings.Heat_Airflow = hvac_sizings.Heat_Airflow * hvac_sizings.Heat_Capacity / prev_capacity
      else
        hvac_sizings.Heat_Airflow = 0.0
      end
    end
  end

  # Applies sizing factors (multipliers) and/or sizing limits (absolute values) to the autosized HVAC capacities.
  # The sizing factors/limits are optional inputs in the HPXML file.
  #
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @return [void]
  def self.apply_hvac_autosizing_factors_and_limits(hvac_sizings, hvac_heating, hvac_cooling)
    if not hvac_cooling.nil?
      cooling_autosizing_limit = hvac_cooling.cooling_autosizing_limit
      if cooling_autosizing_limit.nil?
        cooling_autosizing_limit = 1 / Constants.small
      end

      cooling_autosizing_factor = [hvac_cooling.cooling_autosizing_factor, cooling_autosizing_limit / hvac_sizings.Cool_Capacity].min

      hvac_sizings.Cool_Capacity *= cooling_autosizing_factor
      hvac_sizings.Cool_Airflow *= cooling_autosizing_factor
      hvac_sizings.Cool_Capacity_Sens *= cooling_autosizing_factor
    end
    if not hvac_heating.nil?
      heating_autosizing_limit = hvac_heating.heating_autosizing_limit
      if heating_autosizing_limit.nil?
        heating_autosizing_limit = 1 / Constants.small
      end

      heating_autosizing_factor = [hvac_heating.heating_autosizing_factor, heating_autosizing_limit / hvac_sizings.Heat_Capacity].min

      hvac_sizings.Heat_Capacity *= heating_autosizing_factor
      hvac_sizings.Heat_Airflow *= heating_autosizing_factor
    end
    if (hvac_cooling.is_a? HPXML::HeatPump) && (hvac_cooling.backup_type == HPXML::HeatPumpBackupTypeIntegrated)
      backup_heating_autosizing_limit = hvac_cooling.backup_heating_autosizing_limit
      if backup_heating_autosizing_limit.nil?
        backup_heating_autosizing_limit = 1 / Constants.small
      end

      backup_heating_autosizing_factor = [hvac_cooling.backup_heating_autosizing_factor, backup_heating_autosizing_limit / hvac_sizings.Heat_Capacity_Supp].min

      hvac_sizings.Heat_Capacity_Supp *= backup_heating_autosizing_factor
    end
  end

  # Finalize Capacity Calculations
  #
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.apply_hvac_final_capacities(hvac_sizings, hvac_heating, hvac_cooling, hpxml_bldg)
    # Cooling
    if not hvac_cooling.nil?
      fixed_cooling_capacity = hvac_cooling.cooling_capacity
    end
    autosized_cooling_capacity = hvac_sizings.Cool_Capacity
    if (not fixed_cooling_capacity.nil?) && (autosized_cooling_capacity > 0)
      if not (hpxml_bldg.header.allow_increased_fixed_capacities && autosized_cooling_capacity > fixed_cooling_capacity)
        # Use fixed size; proportionally adjust autosized airflow & sensible capacity
        hvac_sizings.Cool_Capacity = fixed_cooling_capacity
        hvac_sizings.Cool_Airflow *= fixed_cooling_capacity / autosized_cooling_capacity
        hvac_sizings.Cool_Capacity_Sens *= fixed_cooling_capacity / autosized_cooling_capacity
      end
    end

    # Heating
    if not hvac_heating.nil?
      fixed_heating_capacity = hvac_heating.heating_capacity
    elsif (not hvac_cooling.nil?) && hvac_cooling.has_integrated_heating
      fixed_heating_capacity = hvac_cooling.integrated_heating_system_capacity
    end
    autosized_heating_capacity = hvac_sizings.Heat_Capacity
    if (not fixed_heating_capacity.nil?) && (autosized_heating_capacity > 0)
      if not (hpxml_bldg.header.allow_increased_fixed_capacities && autosized_heating_capacity > fixed_heating_capacity)
        # Use fixed size; proportionally adjust autosized airflow
        hvac_sizings.Heat_Capacity = fixed_heating_capacity
        hvac_sizings.Heat_Airflow *= fixed_heating_capacity / autosized_heating_capacity
      end
    end

    # Heat pump backup heating
    if hvac_heating.is_a? HPXML::HeatPump
      if not hvac_heating.backup_heating_capacity.nil?
        fixed_supp_heating_capacity = hvac_heating.backup_heating_capacity
      elsif not hvac_heating.backup_system.nil?
        fixed_supp_heating_capacity = hvac_heating.backup_system.heating_capacity
      end
    end
    autosized_supp_heating_capacity = hvac_sizings.Heat_Capacity_Supp
    if not fixed_supp_heating_capacity.nil?
      if not (hpxml_bldg.header.allow_increased_fixed_capacities && autosized_supp_heating_capacity > fixed_supp_heating_capacity)
        # Use fixed size
        hvac_sizings.Heat_Capacity_Supp = fixed_supp_heating_capacity
      end
    end
  end

  # GSHP Ground Loop Sizing Calculations
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.apply_hvac_ground_loop(mj, runner, hvac_sizings, weather, hvac_cooling, hpxml_bldg)
    cooling_type = get_hvac_cooling_type(hvac_cooling)

    return if cooling_type != HPXML::HVACTypeHeatPumpGroundToAir

    geothermal_loop = hvac_cooling.geothermal_loop

    loop_flow = geothermal_loop.loop_flow
    if loop_flow.nil?
      loop_flow = [1.0, UnitConversions.convert([hvac_sizings.Heat_Capacity, hvac_sizings.Cool_Capacity].max, 'Btu/hr', 'ton')].max.floor * 3.0
    end

    min_bore_depth = 80 # ft; based on g-function library
    # In NY the following is the depth that requires a mining permit, which has been a barrier for Dandelion Energy with installing GSHPs.
    # Sounds like people are pushing ever deeper but for now we can apply this limit and add a note about where it came from.
    max_bore_depth = 500 # ft
    min_num_boreholes = 1
    max_num_boreholes = 10

    num_bore_holes = geothermal_loop.num_bore_holes
    bore_depth = geothermal_loop.bore_length

    if num_bore_holes.nil? || bore_depth.nil?
      # Autosize ground loop heat exchanger length
      nom_length_heat, nom_length_cool = get_geothermal_loop_borefield_ft_per_ton(mj, hpxml_bldg, geothermal_loop, weather, hvac_cooling)
      bore_length_heat = nom_length_heat * UnitConversions.convert(hvac_sizings.Heat_Capacity, 'Btu/hr', 'ton')
      bore_length_cool = nom_length_cool * UnitConversions.convert(hvac_sizings.Cool_Capacity, 'Btu/hr', 'ton')
      bore_length = [bore_length_heat, bore_length_cool].max

      if num_bore_holes.nil? && bore_depth.nil?
        num_bore_holes = [min_num_boreholes, (UnitConversions.convert(hvac_sizings.Cool_Capacity, 'Btu/hr', 'ton') + 0.5).floor].max

        # Divide length by number of boreholes for average bore depth
        bore_depth = (bore_length / num_bore_holes).floor # ft

        # Adjust number of boreholes and bore depth to get within min/max constraints
        for _i in 0..50
          if ((bore_depth < min_bore_depth) || (num_bore_holes > max_num_boreholes)) && (num_bore_holes > min_num_boreholes)
            num_bore_holes -= 1
            bore_depth = (bore_length / num_bore_holes).floor
          elsif ((bore_depth > max_bore_depth) || (num_bore_holes < min_num_boreholes)) && (num_bore_holes < max_num_boreholes)
            num_bore_holes += 1
            bore_depth = (bore_length / num_bore_holes).floor
          end

          if ((num_bore_holes == min_num_boreholes) && (bore_depth < min_bore_depth)) || ((num_bore_holes == max_num_boreholes) && (bore_depth > max_bore_depth))
            break # we can't do any better
          end
        end
      elsif num_bore_holes.nil?
        # Calculate number of boreholes to achieve total autosized length
        num_bore_holes = (bore_length / bore_depth).floor
        num_bore_holes = [num_bore_holes, max_num_boreholes].min
        num_bore_holes = [num_bore_holes, min_num_boreholes].max
      elsif bore_depth.nil?
        # Calculate bore depth to achieve total autosized length
        bore_depth = (bore_length / num_bore_holes).floor # ft
      end
    end

    if bore_depth < min_bore_depth
      bore_depth = min_bore_depth
      runner.registerWarning("Reached a minimum of #{min_num_boreholes} borehole; setting bore depth to the minimum (#{min_bore_depth} ft).")
    end

    if bore_depth > max_bore_depth
      bore_depth = max_bore_depth
      runner.registerWarning("Reached a maximum of #{max_num_boreholes} boreholes; setting bore depth to the maximum (#{max_bore_depth} ft).")
    end

    bore_config = geothermal_loop.bore_config
    if bore_config.nil?
      bore_config = HPXML::GeothermalLoopBorefieldConfigurationRectangle
    end

    g_functions_json = get_geothermal_loop_g_functions_json(get_geothermal_loop_valid_configurations[bore_config])
    valid_num_bores = get_geothermal_loop_valid_num_bores(g_functions_json)

    unless valid_num_bores.include? num_bore_holes
      fail "Number of bore holes (#{num_bore_holes}) with borefield configuration '#{bore_config}' not supported."
    end

    hvac_sizings.GSHP_Loop_Flow = loop_flow
    hvac_sizings.GSHP_Bore_Depth = bore_depth
    hvac_sizings.GSHP_Bore_Holes = num_bore_holes
    hvac_sizings.GSHP_Bore_Config = bore_config

    hvac_sizings.GSHP_G_Functions = get_geothermal_g_functions_data(bore_config, g_functions_json, geothermal_loop, num_bore_holes, bore_depth)
  end

  # Calculates the total needed length of heating/cooling borehole length for the geothermal loop.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param geothermal_loop [HPXML::GeothermalLoop] Geothermal loop of interest
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hvac_cooling [HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @return [Array<Double, Double>] Nominal heating length, nominal cooling length (ft/ton)
  def self.get_geothermal_loop_borefield_ft_per_ton(mj, hpxml_bldg, geothermal_loop, weather, hvac_cooling)
    hvac_cooling_ap = hvac_cooling.additional_properties

    if hvac_cooling_ap.u_tube_spacing_type == 'b'
      beta_0 = 17.4427
      beta_1 = -0.6052
    elsif hvac_cooling_ap.u_tube_spacing_type == 'c'
      beta_0 = 21.9059
      beta_1 = -0.3796
    elsif hvac_cooling_ap.u_tube_spacing_type == 'as'
      beta_0 = 20.1004
      beta_1 = -0.94467
    end

    r_value_ground = Math.log(geothermal_loop.bore_spacing / geothermal_loop.bore_diameter * 12.0) / 2.0 / Math::PI / hpxml_bldg.site.ground_conductivity
    r_value_grout = 1.0 / geothermal_loop.grout_conductivity / beta_0 / ((geothermal_loop.bore_diameter / hvac_cooling_ap.pipe_od)**beta_1)
    r_value_pipe = Math.log(hvac_cooling_ap.pipe_od / hvac_cooling_ap.pipe_id) / 2.0 / Math::PI / hvac_cooling.geothermal_loop.pipe_conductivity
    r_value_bore = r_value_grout + r_value_pipe / 2.0 # Note: Convection resistance is negligible when calculated against Glhepro (Jeffrey D. Spitler, 2000)

    is_southern_hemisphere = (hpxml_bldg.latitude < 0)

    if is_southern_hemisphere
      heating_month = 6 # July
      cooling_month = 0 # January
    else
      heating_month = 0 # January
      cooling_month = 6 # July
    end

    rtf_DesignMon_Heat = [0.25, (71.0 - weather.data.MonthlyAvgDrybulbs[heating_month]) / mj.htd].max
    rtf_DesignMon_Cool = [0.25, (weather.data.MonthlyAvgDrybulbs[cooling_month] - 76.0) / mj.ctd].max

    nom_length_heat = (1.0 - 1.0 / hvac_cooling_ap.heat_rated_cops[0]) * (r_value_bore + r_value_ground * rtf_DesignMon_Heat) / (weather.data.DeepGroundAnnualTemp - (2.0 * hvac_cooling_ap.design_hw - hvac_cooling_ap.design_delta_t) / 2.0) * UnitConversions.convert(1.0, 'ton', 'Btu/hr')
    nom_length_cool = (1.0 + 1.0 / hvac_cooling_ap.cool_rated_cops[0]) * (r_value_bore + r_value_ground * rtf_DesignMon_Cool) / ((2.0 * hvac_cooling_ap.design_chw + hvac_cooling_ap.design_delta_t) / 2.0 - weather.data.DeepGroundAnnualTemp) * UnitConversions.convert(1.0, 'ton', 'Btu/hr')

    return nom_length_heat, nom_length_cool
  end

  # Returns the geothermal loop g-function response factors.
  #
  # @param bore_config [String] Borefield configuration (HPXML::GeothermalLoopBorefieldConfigurationXXX)
  # @param g_functions_json [JSON] JSON object with g-function data
  # @param geothermal_loop [HPXML::GeothermalLoop] Geothermal loop of interest
  # @param num_bore_holes [Integer] Total number of boreholes
  # @param bore_depth [Double] Depth of each borehole (ft)
  # @return [Array<Array<Double>, Array<Double>>] List of g-function lntts (natural log of time/steady state time) values, list of g-function values
  def self.get_geothermal_g_functions_data(bore_config, g_functions_json, geothermal_loop, num_bore_holes, bore_depth)
    actuals = { 'b' => UnitConversions.convert(geothermal_loop.bore_spacing, 'ft', 'm'),
                'h' => UnitConversions.convert(bore_depth, 'ft', 'm'),
                'rb' => UnitConversions.convert(geothermal_loop.bore_diameter / 2.0, 'in', 'm') }
    actuals['b_over_h'] = actuals['b'] / actuals['h']

    g_library = { 24 => { 'b' => 5, 'd' => 2, 'rb' => 0.075 },
                  48 => { 'b' => 5, 'd' => 2, 'rb' => 0.075 },
                  96 => { 'b' => 5, 'd' => 2, 'rb' => 0.075 },
                  192 => { 'b' => 5, 'd' => 2, 'rb' => 0.08 },
                  384 => { 'b' => 5, 'd' => 2, 'rb' => 0.0875 } }
    g_library.each do |h, b_d_rb|
      g_library[h]['b_over_h'] = Float(b_d_rb['b']) / h
      g_library[h]['rb_over_h'] = Float(b_d_rb['rb']) / h
    end

    [[24, 48], [48, 96], [96, 192], [192, 384]].each do |h1, h2|
      next unless actuals['h'] >= h1 && actuals['h'] < h2

      pt1 = g_library[h1]
      pt2 = g_library[h2]

      # linear interpolation on "g" values
      logtimes = []
      gs = []
      [h1, h2].each do |h|
        b_d_rb = g_library[h]
        b = b_d_rb['b']
        rb = b_d_rb['rb']
        b_h_rb = "#{b}._#{h}._#{rb}"

        logtime, g = get_geothermal_loop_g_functions_data_from_json(g_functions_json, bore_config, num_bore_holes, b_h_rb)
        logtimes << logtime
        gs << g
      end
      x = actuals['b_over_h']
      x0 = pt1['b_over_h']
      x1 = pt2['b_over_h']
      g_functions = gs[0].zip(gs[1]).map { |v| MathTools.interp2(x, x0, x1, v[0], v[1]) }

      # linear interpolation on rb/h for correction factor
      x = actuals['b_over_h']
      x0 = pt1['b_over_h']
      x1 = pt2['b_over_h']
      f0 = pt1['rb_over_h']
      f1 = pt2['rb_over_h']
      actuals['rb_over_h'] = MathTools.interp2(x, x0, x1, f0, f1)
      rb = actuals['rb_over_h'] * actuals['h']
      rb_actual_over_rb = actuals['rb'] / rb
      correction_factor = Math.log(rb_actual_over_rb)
      g_functions = g_functions.map { |v| v - correction_factor }

      return logtimes[0], g_functions
    end
  end

  # Returns the geothermal loop g-function logtimes/values for a specific configuration in the JSON file.
  #
  # @param g_functions_json [JSON] JSON object with g-function data
  # @param bore_config [String] Borefield configuration (HPXML::GeothermalLoopBorefieldConfigurationXXX)
  # @param num_bore_holes [Integer] Total number of boreholes
  # @param b_h_rb [String] The lookup key (B._H._rb) in the g-function data.
  # @return [Array<Array<Double>, Array<Double>>] List of logtimes, list of g-function values
  def self.get_geothermal_loop_g_functions_data_from_json(g_functions_json, bore_config, num_bore_holes, b_h_rb)
    g_functions_json.values.each do |values_1|
      if [HPXML::GeothermalLoopBorefieldConfigurationRectangle,
          HPXML::GeothermalLoopBorefieldConfigurationL].include?(bore_config)
        bore_locations = values_1[:bore_locations]
        next if bore_locations.size != num_bore_holes

        logtime = values_1[:logtime].map { |v| Float(v) }
        g = values_1[:g][b_h_rb.to_sym].map { |v| Float(v) }

        return logtime, g
      elsif [HPXML::GeothermalLoopBorefieldConfigurationOpenRectangle,
             HPXML::GeothermalLoopBorefieldConfigurationC,
             HPXML::GeothermalLoopBorefieldConfigurationLopsidedU,
             HPXML::GeothermalLoopBorefieldConfigurationU].include?(bore_config)
        values_1.values.each do |values_2|
          bore_locations = values_2[:bore_locations]
          next if bore_locations.size != num_bore_holes

          logtime = values_2[:logtime].map { |v| Float(v) }
          g = values_2[:g][b_h_rb.to_sym].map { |v| Float(v) }

          return logtime, g
        end
      end
    end
  end

  # Returns a set of valid geothermal loop bore configurations and their corresponding g-function data files.
  #
  # @return [Hash] Map of configuration => datafile
  def self.get_geothermal_loop_valid_configurations
    valid_configs = { HPXML::GeothermalLoopBorefieldConfigurationRectangle => 'rectangle_5m_v1.0.json',
                      HPXML::GeothermalLoopBorefieldConfigurationOpenRectangle => 'Open_configurations_5m_v1.0.json',
                      HPXML::GeothermalLoopBorefieldConfigurationC => 'C_configurations_5m_v1.0.json',
                      HPXML::GeothermalLoopBorefieldConfigurationL => 'L_configurations_5m_v1.0.json',
                      HPXML::GeothermalLoopBorefieldConfigurationU => 'U_configurations_5m_v1.0.json',
                      HPXML::GeothermalLoopBorefieldConfigurationLopsidedU => 'LopU_configurations_5m_v1.0.json' }
    return valid_configs
  end

  # Returns the g-function data for a given geothermal loop configuration.
  #
  # @param g_functions_filename [String] G-function data filename
  # @return [JSON] JSON object with g-function data
  def self.get_geothermal_loop_g_functions_json(g_functions_filename)
    require 'json'

    g_functions_filepath = File.join(File.dirname(__FILE__), 'data/g_functions', g_functions_filename)
    g_functions_json = JSON.parse(File.read(g_functions_filepath), symbolize_names: true)
    return g_functions_json
  end

  # Returns the valid number of boreholes for a given geothermal loop configuration.
  #
  # @param g_functions_json [JSON] JSON object with g-function data
  # @return [Array<Integer>] List of valid numbers of boreholes
  def self.get_geothermal_loop_valid_num_bores(g_functions_json)
    valid_num_bores = []
    g_functions_json.each do |_key_1, values_1|
      if values_1.keys.include?(:bore_locations)
        valid_num_bores << values_1[:bore_locations].size
      else
        values_1.each do |_key_2, values_2|
          if values_2.keys.include?(:bore_locations)
            valid_num_bores << values_2[:bore_locations].size
          end
        end
      end
    end

    return valid_num_bores
  end

  # Updates the HVAC equipment airflows rates to incorporate any airflow defects (HVAC
  # installation quality issues).
  #
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @return [void]
  def self.apply_hvac_final_airflows(hvac_sizings, hvac_heating, hvac_cooling)
    if (not hvac_heating.nil?) && hvac_heating.respond_to?(:airflow_defect_ratio)
      if hvac_sizings.Heat_Airflow > 0
        hvac_sizings.Heat_Airflow *= (1.0 + hvac_heating.airflow_defect_ratio.to_f)
      end
    end

    if (not hvac_cooling.nil?) && hvac_cooling.respond_to?(:airflow_defect_ratio)
      if hvac_sizings.Cool_Airflow > 0
        hvac_sizings.Cool_Airflow *= (1.0 + hvac_cooling.airflow_defect_ratio.to_f)
      end
    end
  end

  # Calculates the heat pump's heating capacity at the specified outdoor/indoor temperatures, as a fraction
  # of the heat pump's nominal heating capacity.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hvac_heating [HPXML::HeatPump] The HPXML heat pump of interest
  # @param heating_temp [Double] Outdoor drybulb temperature (F)
  # @param hvac_heating_speed [Integer] Nominal heating speed index of the HVAC system
  # @return [Double] Heat pump adjustment factor (capacity fraction)
  def self.calculate_heat_pump_adj_factor_at_outdoor_temperature(mj, hvac_heating, heating_temp, hvac_heating_speed)
    if hvac_heating.compressor_type == HPXML::HVACCompressorTypeVariableSpeed
      idb_adj = adjust_indoor_condition_var_speed(heating_temp, mj.heat_setpoint, :htg)
      odb_adj = adjust_outdoor_condition_var_speed(heating_temp, hvac_heating, :htg)
      return odb_adj * idb_adj
    else
      coefficients = hvac_heating.additional_properties.heat_cap_ft_spec[hvac_heating_speed]
      return MathTools.biquadratic(mj.heat_setpoint, heating_temp, coefficients)
    end
  end

  # Calculates the portion of the heating load that the heat pump backup needs to serve.
  # Takes into account the heat pump backup sizing methodology as well as the heat pump's
  # minimum compressor lockout temperature.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param hvac_heating [HPXML::HeatPump] The HPXML heat pump of interest
  # @param heating_load [Double] Full heating load (Btu/hr)
  # @param hp_nominal_heating_capacity [Double] Heat pump nominal heating capacity (Btu/hr)
  # @param hvac_heating_speed [Integer] Nominal heating speed index of the HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Double] Heat pump backup load (Btu/hr)
  def self.calculate_heat_pump_backup_load(mj, hvac_heating, heating_load, hp_nominal_heating_capacity, hvac_heating_speed, hpxml_bldg)
    if hpxml_bldg.header.heat_pump_backup_sizing_methodology == HPXML::HeatPumpBackupSizingEmergency
      # Size backup to meet full design load in case heat pump fails
      return heating_load
    elsif hpxml_bldg.header.heat_pump_backup_sizing_methodology == HPXML::HeatPumpBackupSizingSupplemental
      if not hvac_heating.backup_heating_switchover_temp.nil?
        min_compressor_temp = hvac_heating.backup_heating_switchover_temp
      elsif not hvac_heating.compressor_lockout_temp.nil?
        min_compressor_temp = hvac_heating.compressor_lockout_temp
      end

      if min_compressor_temp > hpxml_bldg.header.manualj_heating_design_temp
        # Heat pump not running at design temperature, size backup to meet full design load
        return heating_load
      end

      # Heat pump operating at design temperature, size backup to meet remaining design load
      heat_cap_adj_factor = calculate_heat_pump_adj_factor_at_outdoor_temperature(mj, hvac_heating, hpxml_bldg.header.manualj_heating_design_temp, hvac_heating_speed)
      hp_output_at_outdoor_temperature = hp_nominal_heating_capacity * heat_cap_adj_factor
      return [heating_load - hp_output_at_outdoor_temperature, 0.0].max
    else
      fail "Unexpected HP backup methodology: #{hpxml_bldg.header.heat_pump_backup_sizing_methodology}"
    end
  end

  # Adjusts heating/cooling capacities for air-source heat pumps based on heat pump sizing methodology,
  # minimum compressor temperature, design loads, heat pump performance curves, etc.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param runner [OpenStudio::Measure::OSRunner] Object typically used to display warnings
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hvac_heating [HPXML::HeatPump] The HPXML heat pump of interest
  # @param cool_cap_adj_factor [Double] Heat pump's cooling capacity at the design temperature as a fraction of the nominal cooling capacity (frac)
  # @param hvac_system [Hash] HPXML HVAC (heating and/or cooling) system
  # @param hvac_heating_speed [Integer] Nominal heating speed index of the HVAC system
  # @param oversize_limit [Double] Oversize fraction (frac)
  # @param oversize_delta [Double] Oversize delta (Btu/hr)
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [void]
  def self.process_heat_pump_adjustment(mj, runner, hvac_sizings, weather, hvac_heating, cool_cap_adj_factor, hvac_system, hvac_heating_speed,
                                        oversize_limit, oversize_delta, hpxml_bldg)

    if not hvac_heating.backup_heating_switchover_temp.nil?
      min_compressor_temp = hvac_heating.backup_heating_switchover_temp
    elsif not hvac_heating.compressor_lockout_temp.nil?
      min_compressor_temp = hvac_heating.compressor_lockout_temp
    end

    if (not min_compressor_temp.nil?) && (min_compressor_temp > hpxml_bldg.header.manualj_heating_design_temp)
      # Calculate the heating load at the switchover temperature to limit unutilized capacity
      temp_heat_design_temp = hpxml_bldg.header.manualj_heating_design_temp
      hpxml_bldg.header.manualj_heating_design_temp = min_compressor_temp
      alternate_all_hvac_sizings = calculate(runner, weather, hpxml_bldg, [hvac_system], update_hpxml: false)
      heating_load = alternate_all_hvac_sizings[hvac_system].Heat_Load
      heating_temp = min_compressor_temp
      hpxml_bldg.header.manualj_heating_design_temp = temp_heat_design_temp
    else
      heating_load = hvac_sizings.Heat_Load
      heating_temp = hpxml_bldg.header.manualj_heating_design_temp
    end

    heat_cap_adj_factor = calculate_heat_pump_adj_factor_at_outdoor_temperature(mj, hvac_heating, heating_temp, hvac_heating_speed)
    heat_cap_rated = heating_load / heat_cap_adj_factor

    if cool_cap_adj_factor.nil? # Heat pump has no cooling
      if hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingMaxLoad
        # Size based on heating, taking into account reduced heat pump capacity at the design temperature
        hvac_sizings.Heat_Capacity = heat_cap_rated
      else
        # Size equal to heating design load
        hvac_sizings.Heat_Capacity = hvac_sizings.Heat_Load
      end
    elsif heat_cap_rated < hvac_sizings.Cool_Capacity
      # Size based on cooling
      hvac_sizings.Heat_Capacity = hvac_sizings.Cool_Capacity
    else
      cfm_per_btuh = hvac_sizings.Cool_Airflow / hvac_sizings.Cool_Capacity
      if hpxml_bldg.header.heat_pump_sizing_methodology == HPXML::HeatPumpSizingMaxLoad
        # Size based on heating, taking into account reduced heat pump capacity at the design temperature
        hvac_sizings.Cool_Capacity = heat_cap_rated
      else
        # Size based on cooling, but with ACCA oversizing allowances for heating
        load_shr = hvac_sizings.Cool_Load_Sens / hvac_sizings.Cool_Load_Tot
        if ((weather.data.HDD65F / weather.data.CDD50F) < 2.0) || (load_shr < 0.95)
          # Mild winter or has a latent cooling load
          hvac_sizings.Cool_Capacity = [(oversize_limit * hvac_sizings.Cool_Load_Tot) / cool_cap_adj_factor, heat_cap_rated].min
        else
          # Cold winter and no latent cooling load (add a ton rule applies)
          hvac_sizings.Cool_Capacity = [(hvac_sizings.Cool_Load_Tot + oversize_delta) / cool_cap_adj_factor, heat_cap_rated].min
        end
      end
      hvac_sizings.Cool_Airflow = cfm_per_btuh * hvac_sizings.Cool_Capacity
      hvac_sizings.Heat_Capacity = hvac_sizings.Cool_Capacity
    end
  end

  # Retrieves a collection of ventilation information from the HPXML building.
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Hash] Airflow rates (cfm) and sensible/latent effectivenesses (frac)
  def self.get_ventilation_data(hpxml_bldg)
    # If CFIS w/ supplemental fan, assume air handler is running the full hour and can provide
    # all ventilation needs (i.e., supplemental fan does not need to run), so skip supplement fan
    vent_fans_mech = hpxml_bldg.ventilation_fans.select { |f| f.used_for_whole_building_ventilation && !f.is_cfis_supplemental_fan && f.flow_rate > 0 && f.hours_in_operation > 0 }
    if vent_fans_mech.empty?
      return { q_imb: 0.0, q_oa: 0.0, q_preheat: 0.0, q_precool: 0.0,
               q_recirc: 0.0, oa_sens_eff: 0.0, oa_lat_eff: 0.0 }
    end

    # Categorize fans into different types
    vent_mech_preheat = vent_fans_mech.select { |vent_mech| (not vent_mech.preheating_efficiency_cop.nil?) }
    vent_mech_precool = vent_fans_mech.select { |vent_mech| (not vent_mech.precooling_efficiency_cop.nil?) }
    vent_mech_shared = vent_fans_mech.select { |vent_mech| vent_mech.is_shared_system }

    vent_mech_sup_tot = vent_fans_mech.select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeSupply }
    vent_mech_exh_tot = vent_fans_mech.select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeExhaust }
    vent_mech_cfis_tot = vent_fans_mech.select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeCFIS }
    vent_mech_bal_tot = vent_fans_mech.select { |vent_mech| vent_mech.fan_type == HPXML::MechVentTypeBalanced }
    vent_mech_erv_hrv_tot = vent_fans_mech.select { |vent_mech| [HPXML::MechVentTypeERV, HPXML::MechVentTypeHRV].include? vent_mech.fan_type }

    # Average in-unit CFMs (include recirculation from in unit CFMs for shared systems)
    q_sup = vent_mech_sup_tot.map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)
    q_exh = vent_mech_exh_tot.map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)
    q_bal = vent_mech_bal_tot.map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)
    q_erv_hrv = vent_mech_erv_hrv_tot.map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)
    q_cfis = vent_mech_cfis_tot.map { |vent_mech| vent_mech.average_unit_flow_rate }.sum(0.0)

    # Average preconditioned OA air CFMs (only OA, recirculation will be addressed below for all shared systems)
    q_preheat = vent_mech_preheat.map { |vent_mech| vent_mech.average_oa_unit_flow_rate * vent_mech.preheating_fraction_load_served }.sum(0.0)
    q_precool = vent_mech_precool.map { |vent_mech| vent_mech.average_oa_unit_flow_rate * vent_mech.precooling_fraction_load_served }.sum(0.0)
    q_recirc = vent_mech_shared.map { |vent_mech| vent_mech.average_unit_flow_rate - vent_mech.average_oa_unit_flow_rate }.sum(0.0)

    # Total CFMs
    q_sup_tot = q_sup + q_bal + q_erv_hrv + q_cfis
    q_exh_tot = q_exh + q_bal + q_erv_hrv
    q_imb = q_exh_tot - q_sup_tot # Worksheet E; used to determine space pressure effect
    q_oa = q_sup_tot - q_cfis # Calculate OA CFM that is considered a space load only (e.g., exclude CFIS, which is considered a system load)

    # Calculate effectiveness for all ERV/HRV and store results in a hash
    hrv_erv_effectiveness_map = Airflow.calc_hrv_erv_effectiveness(vent_mech_erv_hrv_tot)

    # Calculate cfm weighted average effectiveness for the OA space load
    oa_lat_eff = 0.0
    oa_sens_eff = 0.0
    vent_mech_erv_hrv_unprecond = vent_mech_erv_hrv_tot.select { |vent_mech| vent_mech.preheating_efficiency_cop.nil? && vent_mech.precooling_efficiency_cop.nil? }
    vent_mech_erv_hrv_unprecond.each do |vent_mech|
      oa_lat_eff += vent_mech.average_oa_unit_flow_rate / q_oa * hrv_erv_effectiveness_map[vent_mech][:vent_mech_lat_eff]
      oa_sens_eff += vent_mech.average_oa_unit_flow_rate / q_oa * hrv_erv_effectiveness_map[vent_mech][:vent_mech_apparent_sens_eff]
    end

    return { q_imb: q_imb, q_oa: q_oa, q_preheat: q_preheat, q_precool: q_precool,
             q_recirc: q_recirc, oa_sens_eff: oa_sens_eff, oa_lat_eff: oa_lat_eff }
  end

  # Calculates the airflow rate associated with a given load/capacity per ACCA Manual S.
  # Used for central HVAC equipment with an air distribution system.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param sens_load_or_capacity [Double] Load or capacity value to use for calculating corresponding airflow rate (Btu/hr)
  # @param delta_t [Double] Temperature difference (F)
  # @param dx_capacity [Double] Capacity optionally used to apply cfm/ton limits for DX equipment (Btu/hr)
  # @param hp_cooling_cfm [Double] Cooling airflow rate optionally used to ensure a heat pump's heating/cooling airflow rates are similar (cfm)
  # @return [Double] Airflow rate (cfm)
  def self.calc_airflow_rate_manual_s(mj, sens_load_or_capacity, delta_t, dx_capacity: nil, hp_cooling_cfm: nil)
    airflow_cfm = sens_load_or_capacity / (1.1 * mj.acf * delta_t)

    # The following recommendations are from Hugh Henderson.

    if not dx_capacity.nil?
      # For typical DX equipment, ensure the air flow rate is between 300 and 400 cfm/ton.
      rated_capacity_tons = UnitConversions.convert(dx_capacity, 'Btu/hr', 'ton')
      if airflow_cfm / rated_capacity_tons > 400
        airflow_cfm = 400.0 * rated_capacity_tons
      elsif airflow_cfm / rated_capacity_tons < 300
        airflow_cfm = 300.0 * rated_capacity_tons
      end
    end

    if hp_cooling_cfm.to_f > 0
      # For a heat pump, ensure the heating airflow rate is within 30% of the cooling airflow rate.
      airflow_cfm = [airflow_cfm, 0.7 * hp_cooling_cfm].max
      airflow_cfm = [airflow_cfm, 1.3 * hp_cooling_cfm].min
    end

    return airflow_cfm
  end

  # Calculates the airflow rate associated with a given capacity based on the assumed rated cfm/ton.
  # Used for non-central HVAC equipment (no air distribution system).
  #
  # @param capacity [Double] Capacity value to use for calculating corresponding airflow rate (Btu/hr)
  # @param rated_cfm_per_ton [Double] Airflow per ton of rated capacity (cfm/ton)
  # @return [Double] Airflow rate (cfm)
  def self.calc_airflow_rate_user(capacity, rated_cfm_per_ton)
    airflow_cfm = rated_cfm_per_ton * UnitConversions.convert(capacity, 'Btu/hr', 'ton') # Maximum air flow under heating operation
    return airflow_cfm
  end

  # Calculates the ground source heat pump's total/sensible cooling capacities at the design conditions as a fraction of the nominal cooling capacity.
  #
  # @param cool_cap_curve_spec [Array<Double>] Total cooling capacity performance curve coefficients
  # @param cool_sh_curve_spec [Array<Double>] Sensible cooling capacity performance curve coefficients
  # @param wb_temp [Double] Indoor design wetbulb temperature (F)
  # @param db_temp [Double] Indoor design drybulb temperature (F)
  # @param w_temp [Double] Temperature of water entering indoor coil (F)
  # @param vfr_air [Double] Cooling design airflow rate (cfm)
  # @return [Double] Total capacity fraction of nominal, Sensible capacity fraction of nominal
  def self.calc_gshp_clg_curve_value(cool_cap_curve_spec, cool_sh_curve_spec, wb_temp, db_temp, w_temp, vfr_air)
    # Reference conditions in thesis with largest capacity:
    # See Appendix B Figure B.3 of  https://hvac.okstate.edu/sites/default/files/pubs/theses/MS/27-Tang_Thesis_05.pdf
    ref_temp = 283 # K
    ref_vfr_air = UnitConversions.convert(1200, 'cfm', 'm^3/s') # rated volume flow rate used to fit the curve
    ref_vfr_water = 0.000284

    a_1 = cool_cap_curve_spec[0]
    a_2 = cool_cap_curve_spec[1]
    a_3 = cool_cap_curve_spec[2]
    a_4 = cool_cap_curve_spec[3]
    a_5 = cool_cap_curve_spec[4]
    b_1 = cool_sh_curve_spec[0]
    b_2 = cool_sh_curve_spec[1]
    b_3 = cool_sh_curve_spec[2]
    b_4 = cool_sh_curve_spec[3]
    b_5 = cool_sh_curve_spec[4]
    b_6 = cool_sh_curve_spec[5]

    loop_flow = 0.0 # Neglecting the water flow rate for now because it's not available yet

    wb_temp = UnitConversions.convert(wb_temp, 'F', 'K')
    db_temp = UnitConversions.convert(db_temp, 'F', 'K')
    w_temp = UnitConversions.convert(w_temp, 'F', 'K')
    vfr_air = UnitConversions.convert(vfr_air, 'cfm', 'm^3/s')

    total_cap_curve_value = a_1 + wb_temp / ref_temp * a_2 + w_temp / ref_temp * a_3 + vfr_air / ref_vfr_air * a_4 + loop_flow / ref_vfr_water * a_5
    sensible_cap_curve_value = b_1 + db_temp / ref_temp * b_2 + wb_temp / ref_temp * b_3 + w_temp / ref_temp * b_4 + vfr_air / ref_vfr_air * b_5 + loop_flow / ref_vfr_water * b_6

    return total_cap_curve_value, sensible_cap_curve_value
  end

  # Calculates the effectiveness of the air distribution system during heating.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param q_s [Double] Heating supply duct leakage (cfm)
  # @param q_r [Double] Heating return duct leakage (cfm)
  # @param system_cfm [Double] Total system airflow rate (cfm)
  # @param load_sens [Double] Sensible heating load (Btu/hr)
  # @param t_amb_s [Double] Ambient temperature of supply duct location (F)
  # @param t_amb_r [Double] Ambient temperature of return duct location (F)
  # @param area_s [Double] Supply duct surface area (ft2)
  # @param area_r [Double] Return duct surface area (ft2)
  # @param t_setpoint [Double] HVAC setpoint temperature (F)
  # @param f_regain_s [Double] Supply duct regain factor (frac)
  # @param f_regain_r [Double] Return duct regain factor (frac)
  # @param rvalue_s [Double] Supply duct R-value (hr-ft2-F/Btu)
  # @param rvalue_r [Double] Return duct R-value (hr-ft2-F/Btu)
  # @return [Double] Heating delivery effectiveness of the distribution system
  def self.calc_delivery_effectiveness_heating(mj, q_s, q_r, system_cfm, load_sens, t_amb_s, t_amb_r, area_s, area_r, t_setpoint, f_regain_s, f_regain_r, rvalue_s, rvalue_r)
    b_s, b_r = _calc_de_conduction_fractions(area_s, area_r, rvalue_s, rvalue_r, system_cfm, mj.indoor_air_density, Gas.Air.cp)
    a_s, a_r = _calc_de_leakage_factors(q_s, q_r, system_cfm)
    dt_e, dt_s, dt_r = _calc_de_temperature_differences(t_amb_s, t_amb_r, system_cfm, load_sens, t_setpoint, mj.indoor_air_density, Gas.Air.cp)
    de = _calc_de_heating(a_s, b_s, a_r, b_r, dt_s, dt_r, dt_e)
    decorr = _calc_decorr(de, f_regain_s, f_regain_r, b_r, a_r, dt_r, dt_e)

    return decorr
  end

  # Calculates the effectiveness of the air distribution system during cooling.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param q_s [Double] Heating supply duct leakage (cfm)
  # @param q_r [Double] Heating return duct leakage (cfm)
  # @param leaving_air_temp [Double] HVAC system leaving air temperature (F)
  # @param system_cfm [Double] Total system airflow rate (cfm)
  # @param load_sens [Double] Sensible cooling load (Btu/hr)
  # @param load_total [Double] Total cooling load (Btu/hr)
  # @param t_amb_s [Double] Ambient temperature of supply duct location (F)
  # @param t_amb_r [Double] Ambient temperature of return duct location (F)
  # @param area_s [Double] Supply duct surface area (ft2)
  # @param area_r [Double] Return duct surface area (ft2)
  # @param t_setpoint [Double] HVAC setpoint temperature (F)
  # @param f_regain_s [Double] Supply duct regain factor (frac)
  # @param f_regain_r [Double] Return duct regain factor (frac)
  # @param h_r [Double] Air enthalpy in return duct location (Btu/lb)
  # @param rvalue_s [Double] Supply duct R-value (hr-ft2-F/Btu)
  # @param rvalue_r [Double] Return duct R-value (hr-ft2-F/Btu)
  # @return [Double] Cooling delivery effectiveness of the distribution system
  def self.calc_delivery_effectiveness_cooling(mj, q_s, q_r, leaving_air_temp, system_cfm, load_sens, load_total, t_amb_s, t_amb_r, area_s, area_r, t_setpoint, f_regain_s, f_regain_r, h_r, rvalue_s, rvalue_r)
    b_s, b_r = _calc_de_conduction_fractions(area_s, area_r, rvalue_s, rvalue_r, system_cfm, mj.indoor_air_density, Gas.Air.cp)
    a_s, a_r = _calc_de_leakage_factors(q_s, q_r, system_cfm)
    dt_e, _dt_s, dt_r = _calc_de_temperature_differences(t_amb_s, t_amb_r, system_cfm, load_sens, t_setpoint, mj.indoor_air_density, Gas.Air.cp)
    de = _calc_de_cooling(a_s, system_cfm, load_total, a_r, h_r, b_r, dt_r, b_s, leaving_air_temp, t_amb_s, mj.indoor_air_density, Gas.Air.cp, mj.cool_indoor_enthalpy)
    decorr = _calc_decorr(de, f_regain_s, f_regain_r, b_r, a_r, dt_r, -dt_e)

    return decorr
  end

  # Calculates supply and return duct conduction factors for delivery effectiveness.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param area_s [Double] Supply duct surface area (ft2)
  # @param area_r [Double] Return duct surface area (ft2)
  # @param rvalue_s [Double] Supply duct R-value (hr-ft2-F/Btu)
  # @param rvalue_r [Double] Return duct R-value (hr-ft2-F/Btu)
  # @param system_cfm [Double] Total system airflow rate (cfm)
  # @param air_dens [Double] Indoor air density (lb/ft3)
  # @param air_cp [Double] Air specific heat (Btu/lb-R)
  # @return [Array<Double, Double>] Supply/return conduction factors
  def self._calc_de_conduction_fractions(area_s, area_r, rvalue_s, rvalue_r, system_cfm, air_dens, air_cp)
    b_s = Math.exp((-1.0 * area_s) / (60.0 * system_cfm * air_dens * air_cp * rvalue_s))
    b_r = Math.exp((-1.0 * area_r) / (60.0 * system_cfm * air_dens * air_cp * rvalue_r))
    return b_s, b_r
  end

  # Calculates supply and return leakage factors for delivery effectiveness.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param q_s [Double] Heating supply duct leakage (cfm)
  # @param q_r [Double] Heating return duct leakage (cfm)
  # @param system_cfm [Double] Total system airflow rate (cfm)
  # @return [Array<Double, Double>] Supply/return leakage factors (frac)
  def self._calc_de_leakage_factors(q_s, q_r, system_cfm)
    a_s = (system_cfm - q_s) / system_cfm
    a_r = (system_cfm - q_r) / system_cfm
    return a_s, a_r
  end

  # Calculates temperature differences for delivery effectiveness.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param t_amb_s [Double] Ambient temperature of supply duct location (F)
  # @param t_amb_r [Double] Ambient temperature of return duct location (F)
  # @param system_cfm [Double] Total system airflow rate (cfm)
  # @param load_sens [Double] Sensible load (Btu/hr)
  # @param t_setpoint [Double] HVAC setpoint temperature (F)
  # @param air_dens [Double] Indoor air density (lb/ft3)
  # @param air_cp [Double] Air specific heat (Btu/lb-R)
  # @return [Array<Double, Double, Double>] Heat exchanger temperature difference, supply/return temperature differences (F)
  def self._calc_de_temperature_differences(t_amb_s, t_amb_r, system_cfm, load_sens, t_setpoint, air_dens, air_cp)
    dt_e = load_sens / (60.0 * system_cfm * air_dens * air_cp)
    dt_s = t_setpoint - t_amb_s
    dt_r = t_setpoint - t_amb_r
    return dt_e, dt_s, dt_r
  end

  # Calculates the delivery effectiveness for cooling.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param a_s [Double] Supply duct leakage factor (frac)
  # @param system_cfm [Double] Total system airflow rate (cfm)
  # @param load_total [Double] Total cooling load (Btu/hr)
  # @param a_r [Double] Return duct leakage factor (frac)
  # @param h_r [Double] Air enthalpy in return duct location (Btu/lb)
  # @param b_r [Double] Return duct conduction fraction (frac)
  # @param dt_r [Double] Temperature difference between indoors and return duct ambient temperature (F)
  # @param b_s [Double] Supply duct conduction fraction (frac)
  # @param leaving_air_temp [Double] HVAC system leaving air temperature (F)
  # @param t_amb_s [Double] Ambient temperature of supply duct location (F)
  # @param air_dens [Double] Indoor air density (lb/ft3)
  # @param air_cp [Double] Air specific heat (Btu/lb-R)
  # @param h_in [Double] Indoor enthalpy (Btu/lb)
  # @return [Double] Delivery effectiveness
  def self._calc_de_cooling(a_s, system_cfm, load_total, a_r, h_r, b_r, dt_r, b_s, leaving_air_temp, t_amb_s, air_dens, air_cp, h_in)
    # Calculate the delivery effectiveness (Equation 6-25)
    de = ((a_s * 60.0 * system_cfm * air_dens) / (-1.0 * load_total)) * \
         (((-1.0 * load_total) / (60.0 * system_cfm * air_dens)) + \
          (1.0 - a_r) * (h_r - h_in) + \
          a_r * air_cp * (b_r - 1.0) * dt_r + \
          air_cp * (b_s - 1.0) * (leaving_air_temp - t_amb_s))

    return de
  end

  # Calculates the delivery effectiveness for heating.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param a_s [Double] Supply duct leakage factor (frac)
  # @param b_s [Double] Supply duct conduction fraction (frac)
  # @param a_r [Double] Return duct leakage factor (frac)
  # @param b_r [Double] Return duct conduction fraction (frac)
  # @param dt_s [Double] Temperature difference between indoors and supply duct ambient temperature (F)
  # @param dt_r [Double] Temperature difference between indoors and return duct ambient temperature (F)
  # @param dt_e [Double] Temperature difference across heat exchanger (F)
  # @return [Double] Delivery effectiveness
  def self._calc_de_heating(a_s, b_s, a_r, b_r, dt_s, dt_r, dt_e)
    # Calculate the delivery effectiveness (Equation 6-23)
    de = (a_s * b_s -
              a_s * b_s * (1.0 - a_r * b_r) * (dt_r / dt_e) -
              a_s * (1.0 - b_s) * (dt_s / dt_e))

    return de
  end

  # Calculates the delivery effectiveness corrected for regain.
  #
  # Source: ASHRAE Standard 152 "Method of Test for Determining the Design and Seasonal Efficiencies
  # of Residential Thermal Distribution Systems"
  #
  # @param de [Double] Delivered effectiveness (without regain)
  # @param f_regain_s [Double] Supply duct regain factor (frac)
  # @param f_regain_r [Double] Return duct regain factor (frac)
  # @param b_r [Double] Return duct conduction fraction (frac)
  # @param a_r [Double] Return duct leakage factor (frac)
  # @param dt_r [Double] Temperature difference between indoors and return duct ambient temperature (F)
  # @param dt_e [Double] Temperature difference across heat exchanger (F)
  # @return [Double] Corrected delivery effectiveness
  def self._calc_decorr(de, f_regain_s, f_regain_r, b_r, a_r, dt_r, dt_e)
    # Equation 6-40
    decorr = (de + f_regain_s * (1.0 - de) - (f_regain_s - f_regain_r -
                  b_r * (a_r * f_regain_s - f_regain_r)) * dt_r / dt_e)

    # Limit the DE to a reasonable value to prevent negative values and huge equipment
    decorr = [decorr, 0.25].max
    decorr = [decorr, 1.00].min

    return decorr
  end

  # Calculates the latent duct leakage load (Manual J accounts only for return duct leakage).
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param return_leakage_cfm [Double] Return duct leakage (cfm)
  # @param cool_load_tot [Double] Total cooling load excluding ducts (Btu/hr)
  # @param cool_load_lat [Double] Latent cooling load excluding ducts (Btu/hr)
  # @return [Array<Double, Double>] Latent cooling load including ducts, Sensible cooling load including ducts (Btu/hr)
  def self.calculate_sensible_latent_split(mj, return_leakage_cfm, cool_load_tot, cool_load_lat)
    cool_load_latent = [0.0, 0.68 * mj.acf * return_leakage_cfm * mj.cool_design_grains].max

    # Calculate final latent and load
    cool_load_lat += cool_load_latent
    cool_load_sens = cool_load_tot - cool_load_lat

    return cool_load_lat, cool_load_sens
  end

  # Returns a variety of area-weighted duct values for a given HVAC distribution system.
  #
  # @param distribution_system [HPXML::HVACDistribution] HVAC distribution system of interest
  # @param design_temps [Hash] Map of HPXML locations => design temperatures (F)
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Array<Double, Double, Double, Double, Double, Double, Double, Double>] Supply/return area (ft2), supply/return R-value (hr-ft2-F/Btu), supply/return ambient temperature (F), supply/return regain factors (frac)
  def self.calc_duct_conduction_values(distribution_system, design_temps, hpxml_bldg)
    dse_a = { HPXML::DuctTypeSupply => 0.0, HPXML::DuctTypeReturn => 0.0 }
    dse_ufactor = { HPXML::DuctTypeSupply => 0.0, HPXML::DuctTypeReturn => 0.0 }
    dse_t_amb = { HPXML::DuctTypeSupply => 0.0, HPXML::DuctTypeReturn => 0.0 }
    dse_f_regain = { HPXML::DuctTypeSupply => 0.0, HPXML::DuctTypeReturn => 0.0 }

    [HPXML::DuctTypeSupply, HPXML::DuctTypeReturn].each do |duct_type|
      # Calculate total area outside this unit's conditioned space
      total_area = 0.0
      distribution_system.ducts.each do |duct|
        next if duct.duct_type != duct_type
        next if HPXML::conditioned_locations_this_unit.include? duct.duct_location

        total_area += duct.duct_surface_area * duct.duct_surface_area_multiplier
      end

      if total_area == 0
        # There still may be leakage to the outside, so set t_amb to outside environment
        dse_t_amb[duct_type] = design_temps[HPXML::LocationOutside]
      else
        distribution_system.ducts.each do |duct|
          next if duct.duct_type != duct_type
          next if HPXML::conditioned_locations_this_unit.include? duct.duct_location

          duct_area = duct.duct_surface_area * duct.duct_surface_area_multiplier
          dse_a[duct_type] += duct_area

          # Calculate area-weighted values:
          duct_area_fraction = duct_area / total_area
          dse_ufactor[duct_type] += 1.0 / duct.duct_effective_r_value * duct_area_fraction
          dse_t_amb[duct_type] += design_temps[duct.duct_location] * duct_area_fraction
          dse_f_regain[duct_type] += get_duct_regain_factor(duct, hpxml_bldg) * duct_area_fraction
        end
      end
    end

    return dse_a[HPXML::DuctTypeSupply], dse_a[HPXML::DuctTypeReturn],
           1.0 / dse_ufactor[HPXML::DuctTypeSupply], 1.0 / dse_ufactor[HPXML::DuctTypeReturn],
           dse_t_amb[HPXML::DuctTypeSupply], dse_t_amb[HPXML::DuctTypeReturn],
           dse_f_regain[HPXML::DuctTypeSupply], dse_f_regain[HPXML::DuctTypeReturn]
  end

  # Calculates supply & return duct leakage in cfm25.
  #
  # @param distribution_system [HPXML::HVACDistribution] HVAC distribution system of interest
  # @param system_cfm [Double] Total system airflow rate (cfm)
  # @return [Array<Double, Double>] Supply duct leakage (cfm), Return duct leakage (cfm)
  def self.calc_duct_leakages_cfm25(distribution_system, system_cfm)
    cfms = { HPXML::DuctTypeSupply => 0.0, HPXML::DuctTypeReturn => 0.0 }

    distribution_system.duct_leakage_measurements.each do |m|
      next if m.duct_leakage_total_or_to_outside != HPXML::DuctLeakageToOutside
      next unless [HPXML::DuctTypeSupply, HPXML::DuctTypeReturn].include? m.duct_type

      if m.duct_leakage_units == HPXML::UnitsPercent
        cfms[m.duct_type] += m.duct_leakage_value * system_cfm
      elsif m.duct_leakage_units == HPXML::UnitsCFM25
        cfms[m.duct_type] += m.duct_leakage_value
      elsif m.duct_leakage_units == HPXML::UnitsCFM50
        cfms[m.duct_type] += Airflow.calc_air_leakage_at_diff_pressure(0.65, m.duct_leakage_value, 50.0, 25.0)
      end
    end

    return cfms[HPXML::DuctTypeSupply], cfms[HPXML::DuctTypeReturn]
  end

  # This method is being deleted in https://github.com/NREL/OpenStudio-HPXML/pull/1707
  def self.process_curve_fit(airflow_rate, capacity, temp)
    # TODO: Get rid of this curve by using ADP/BF calculations
    return 0 if capacity == 0

    capacity_tons = UnitConversions.convert(capacity, 'Btu/hr', 'ton')
    return MathTools.biquadratic(airflow_rate / capacity_tons, temp, get_shr_biquadratic)
  end

  # This method is being deleted in https://github.com/NREL/OpenStudio-HPXML/pull/1707
  def self.get_shr_biquadratic
    # Based on EnergyPlus's model for calculating SHR at off-rated conditions. This curve fit
    # avoids the iterations in the actual model. It does not account for altitude or variations
    # in the SHRRated. It is a function of ODB (MJ design temp) and CFM/Ton (from MJ)
    return [1.08464364, 0.002096954, 0, -0.005766327, 0, -0.000011147]
  end

  # Determines the nominal speed (of a multi/variable-speed system).
  #
  # @param hvac_ap [HPXML::AdditionalProperties] AdditionalProperties object for the HVAC system
  # @param is_cooling [Boolean] True if cooling, otherwise heating
  # @return [Integer] Array index of the nominal speed
  def self.get_nominal_speed(hvac_ap, is_cooling)
    if is_cooling && hvac_ap.respond_to?(:cool_capacity_ratios)
      capacity_ratios = hvac_ap.cool_capacity_ratios
    elsif (not is_cooling) && hvac_ap.respond_to?(:heat_capacity_ratios)
      capacity_ratios = hvac_ap.heat_capacity_ratios
    end
    if not capacity_ratios.nil?
      nominal_speed = capacity_ratios.index(1.0)

      if nominal_speed.nil?
        fail 'No nominal speed (with capacity ratio of 1.0) found.'
      end

      return nominal_speed
    end
    return 0
  end

  # Converts the HPXML azimuth convention to the Manual J azimuth convention.
  #
  # @param azimuth [Double] HPXML azimuth
  # @return [Double] Manual J azimuth
  def self.get_mj_azimuth(azimuth)
    true_az = azimuth - 180.0
    if true_az < 0
      true_az += 360.0
    end
    return true_az
  end

  # Calculates UA (U-factor times Area) values for a HPXML location.
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param location [String] The location of interest (HPXML::LocationXXX)
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @return [Hash] UA values for adjacency to outdoor air, ground, or conditioned space (Btu/hr-F)
  def self.get_space_ua_values(mj, location, weather, hpxml_bldg)
    if HPXML::conditioned_locations.include? location
      fail 'Method should not be called for a conditioned space.'
    end

    space_UAs = { HPXML::LocationOutside => 0.0,
                  HPXML::LocationGround => 0.0,
                  HPXML::LocationConditionedSpace => 0.0 }

    # Surface UAs
    hpxml_bldg.surfaces.each do |surface|
      next unless (surface.is_a? HPXML::Slab
                   (location == surface.interior_adjacent_to && space_UAs.keys.include?(surface.exterior_adjacent_to)) ||
                   (location == surface.exterior_adjacent_to && space_UAs.keys.include?(surface.interior_adjacent_to)))

      if [surface.interior_adjacent_to, surface.exterior_adjacent_to].include? HPXML::LocationOutside
        space_UAs[HPXML::LocationOutside] += (1.0 / surface.insulation_assembly_r_value) * surface.area
      elsif HPXML::conditioned_locations.include?(surface.interior_adjacent_to) || HPXML::conditioned_locations.include?(surface.exterior_adjacent_to)
        space_UAs[HPXML::LocationConditionedSpace] += (1.0 / surface.insulation_assembly_r_value) * surface.area
      elsif [surface.interior_adjacent_to, surface.exterior_adjacent_to].include? HPXML::LocationGround
        # Ground temperature is used for basements, not crawlspaces, per Walker (1998)
        # "Technical background for default values used for forced air systems in proposed ASHRAE Std. 152"
        if [HPXML::LocationCrawlspaceVented, HPXML::LocationCrawlspaceUnvented].include? location
          ua_location = HPXML::LocationOutside
        else
          ua_location = HPXML::LocationGround
        end
        if surface.is_a? HPXML::FoundationWall
          u_wall_without_soil = get_foundation_wall_ufactor(surface, false, mj.ground_conductivity)
          space_UAs[ua_location] += u_wall_without_soil * surface.area
        elsif surface.is_a? HPXML::Slab
          if surface.thickness == 0
            # Dirt floor, assume U-value=0.1 per Walker (1998) "Technical background for default
            # values used for forced air systems in proposed ASHRAE Std. 152"
            space_UAs[ua_location] += 0.1 * surface.area
          else
            concrete_r = Material.Concrete(surface.thickness).rvalue
            # Under Slab Insulation UA
            horiz_insul_u = 1.0 / (concrete_r + surface.under_slab_insulation_r_value)
            if surface.under_slab_insulation_spans_entire_slab
              horiz_insul_a = surface.area
            else
              horiz_insul_a = surface.under_slab_insulation_width * surface.exposed_perimeter
            end
            space_UAs[ua_location] += horiz_insul_u * horiz_insul_a
            # Perimeter Insulation UA (approximate as similar to under slab insulation)
            vert_insul_u = 1.0 / (concrete_r + surface.perimeter_insulation_r_value)
            vert_insul_a = surface.perimeter_insulation_depth * surface.exposed_perimeter
            space_UAs[ua_location] += vert_insul_u * vert_insul_a
            # Uninsulated slab UA
            slab_u = 1.0 / concrete_r
            slab_a = [surface.area - horiz_insul_a - vert_insul_a, 0.0].max
            space_UAs[ua_location] += slab_u * slab_a
          end
        end
      end
    end

    # Infiltration UA
    ach = nil
    if HPXML::vented_locations.include? location
      # Vented space
      if location == HPXML::LocationCrawlspaceVented
        vented_crawl = hpxml_bldg.foundations.find { |f| f.foundation_type == HPXML::FoundationTypeCrawlspaceVented }
        sla = vented_crawl.vented_crawlspace_sla
      else
        vented_attic = hpxml_bldg.attics.find { |f| f.attic_type == HPXML::AtticTypeVented }
        if not vented_attic.vented_attic_sla.nil?
          sla = vented_attic.vented_attic_sla
        else
          ach = vented_attic.vented_attic_ach
        end
      end
      ach = Airflow.get_infiltration_ACH_from_SLA(sla, 8.202, weather) if ach.nil?
    else # Unvented space
      ach = Airflow.get_default_unvented_space_ach()
    end
    volume = Geometry.calculate_zone_volume(hpxml_bldg: hpxml_bldg, location: location)
    infiltration_cfm = ach / UnitConversions.convert(1.0, 'hr', 'min') * volume
    space_UAs[HPXML::LocationOutside] += infiltration_cfm * mj.outside_air_density * Gas.Air.cp * UnitConversions.convert(1.0, 'hr', 'min')

    return space_UAs
  end

  # Calculates the heating or cooling design temperature for a HPXML location using a simple
  # UA-based heat balance method. (Unvented attics w/ roof insulation are handled as a special case.)
  #
  # @param mj [MJValues] Object with a collection of misc Manual J values
  # @param location [String] The location of interest (HPXML::LocationXXX)
  # @param weather [WeatherFile] Weather object containing EPW information
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param setpoint_temp [Double] The conditioned space heating or cooling setpoint temperature (F)
  # @param design_db [Double] The outdoor heating or cooling design temperature (F)
  # @param ground_db [Double] The approximate ground temperature during the heating or cooling season (F)
  # @param is_unvented_attic_with_roof_insul [Boolean] Whether we are calculating the design temperature for an unvented attic with roof insulation
  # @return [Double] The location's design temperature (F)
  def self.calculate_space_design_temp(mj, location, weather, hpxml_bldg, setpoint_temp, design_db, ground_db, is_unvented_attic_with_roof_insul)
    space_UAs = get_space_ua_values(mj, location, weather, hpxml_bldg)

    # Calculate space design temp from space UAs
    design_temp = nil
    if not is_unvented_attic_with_roof_insul

      sum_uat, sum_ua = 0.0, 0.0
      space_UAs.each do |ua_type, ua|
        if ua_type == HPXML::LocationGround
          sum_uat += ua * ground_db
          sum_ua += ua
        elsif ua_type == HPXML::LocationOutside
          sum_uat += ua * design_db
          sum_ua += ua
        elsif ua_type == HPXML::LocationConditionedSpace
          sum_uat += ua * setpoint_temp
          sum_ua += ua
        else
          fail "Unexpected space ua type: '#{ua_type}'."
        end
      end
      design_temp = sum_uat / sum_ua

    else

      # Special case due to effect of solar

      # This number comes from the number from the Vented Attic
      # assumption, but assuming an unvented attic will be hotter
      # during the summer when insulation is at the ceiling level
      max_temp_rise = 50.0

      # Estimate from running a few cases in E+ and DOE2 since the
      # attic will always be a little warmer than the conditioned space
      # when the roof is insulated
      min_temp_rise = 5.0

      max_cooling_temp = mj.cool_setpoint + max_temp_rise
      min_cooling_temp = mj.cool_setpoint + min_temp_rise

      ua_conditioned = 0.0
      ua_outside = 0.0
      space_UAs.each do |ua_type, ua|
        if ua_type == HPXML::LocationOutside
          ua_outside += ua
        elsif ua_type == HPXML::LocationConditionedSpace
          ua_conditioned += ua
        elsif ua_type != HPXML::LocationGround
          fail "Unexpected space ua type: '#{ua_type}'."
        end
      end
      percent_ua_conditioned = ua_conditioned / (ua_conditioned + ua_outside)
      design_temp = max_cooling_temp - percent_ua_conditioned * (max_cooling_temp - min_cooling_temp)

    end

    return design_temp
  end

  # Retrieves the design temperature for a space that uses scheduled temperatures (e.g., multifamily
  # spaces when modeling an individual dwelling unit).
  #
  # @param location [String] The location of interest (HPXML::LocationXXX)
  # @param setpoint_temp [Double] The conditioned space heating or cooling setpoint temperature (F)
  # @param outdoor_design_temp [Double] The outdoor heating or cooling design temperature (F)
  # @param ground_temp [Double] The approximate ground temperature during the heating or cooling season (F)
  # @return [Double] The location's design temperature (F)
  def self.calculate_scheduled_space_design_temps(location, setpoint_temp, outdoor_design_temp, ground_temp)
    space_values = Geometry.get_temperature_scheduled_space_values(location: location)
    design_temp = setpoint_temp * space_values[:indoor_weight] + outdoor_design_temp * space_values[:outdoor_weight] + ground_temp * space_values[:ground_weight]
    if not space_values[:temp_min].nil?
      design_temp = [design_temp, space_values[:temp_min]].max
    end
    return design_temp
  end

  # Determines the ASHRAE Group Number G-B (based on the Table 4A Group Number A-K) for above-grade walls.
  #
  # @param wall [HPXML::Wall or HPXML::RimJoist] The wall or rim joist of interest
  # @return [String] ASHRAE Group Number
  def self.get_ashrae_wall_group(wall)
    if wall.is_a? HPXML::RimJoist
      wall_type = HPXML::WallTypeWoodStud
    else
      wall_type = wall.wall_type
    end

    wall_ufactor = 1.0 / wall.insulation_assembly_r_value

    # The following correlations were estimated by analyzing MJ8 construction tables.
    if wall_type == HPXML::WallTypeWoodStud
      if wall.siding == HPXML::SidingTypeBrick
        if wall_ufactor <= 0.070
          table_4a_wall_group = 'K'
        elsif wall_ufactor <= 0.083
          table_4a_wall_group = 'J'
        elsif wall_ufactor <= 0.095
          table_4a_wall_group = 'I'
        elsif wall_ufactor <= 0.100
          table_4a_wall_group = 'H'
        elsif wall_ufactor <= 0.130
          table_4a_wall_group = 'G'
        elsif wall_ufactor <= 0.175
          table_4a_wall_group = 'F'
        else
          table_4a_wall_group = 'E'
        end
      else
        if wall_ufactor <= 0.048
          table_4a_wall_group = 'J'
        elsif wall_ufactor <= 0.051
          table_4a_wall_group = 'I'
        elsif wall_ufactor <= 0.059
          table_4a_wall_group = 'H'
        elsif wall_ufactor <= 0.063
          table_4a_wall_group = 'G'
        elsif wall_ufactor <= 0.067
          table_4a_wall_group = 'F'
        elsif wall_ufactor <= 0.075
          table_4a_wall_group = 'E'
        elsif wall_ufactor <= 0.086
          table_4a_wall_group = 'D'
        elsif wall_ufactor <= 0.110
          table_4a_wall_group = 'C'
        elsif wall_ufactor <= 0.170
          table_4a_wall_group = 'B'
        else
          table_4a_wall_group = 'A'
        end
      end

    elsif wall_type == HPXML::WallTypeSteelStud
      if wall.siding == HPXML::SidingTypeBrick
        if wall_ufactor <= 0.090
          table_4a_wall_group = 'K'
        elsif wall_ufactor <= 0.105
          table_4a_wall_group = 'J'
        elsif wall_ufactor <= 0.118
          table_4a_wall_group = 'I'
        elsif wall_ufactor <= 0.125
          table_4a_wall_group = 'H'
        elsif wall_ufactor <= 0.145
          table_4a_wall_group = 'G'
        elsif wall_ufactor <= 0.200
          table_4a_wall_group = 'F'
        else
          table_4a_wall_group = 'E'
        end
      else
        if wall_ufactor <= 0.066
          table_4a_wall_group = 'J'
        elsif wall_ufactor <= 0.070
          table_4a_wall_group = 'I'
        elsif wall_ufactor <= 0.075
          table_4a_wall_group = 'H'
        elsif wall_ufactor <= 0.081
          table_4a_wall_group = 'G'
        elsif wall_ufactor <= 0.088
          table_4a_wall_group = 'F'
        elsif wall_ufactor <= 0.100
          table_4a_wall_group = 'E'
        elsif wall_ufactor <= 0.105
          table_4a_wall_group = 'D'
        elsif wall_ufactor <= 0.120
          table_4a_wall_group = 'C'
        elsif wall_ufactor <= 0.200
          table_4a_wall_group = 'B'
        else
          table_4a_wall_group = 'A'
        end
      end

    elsif wall_type == HPXML::WallTypeDoubleWoodStud
      table_4a_wall_group = 'J' # assumed since MJ8 does not include double stud constructions
      if wall.siding == HPXML::SidingTypeBrick
        table_4a_wall_group = 'K'
      end

    elsif wall_type == HPXML::WallTypeSIP
      # Manual J refers to SIPs as Structural Foam Panel (SFP)
      if wall_ufactor >= (0.072 + 0.050) / 2
        if wall.siding == HPXML::SidingTypeBrick
          table_4a_wall_group = 'J'
        else
          table_4a_wall_group = 'G'
        end
      elsif wall_ufactor >= 0.050
        if wall.siding == HPXML::SidingTypeBrick
          table_4a_wall_group = 'K'
        else
          table_4a_wall_group = 'I'
        end
      else
        table_4a_wall_group = 'K'
      end

    elsif wall_type == HPXML::WallTypeCMU
      # Table 4A - Construction Number 13
      if wall_ufactor <= 0.0575
        table_4a_wall_group = 'J'
      elsif wall_ufactor <= 0.067
        table_4a_wall_group = 'I'
      elsif wall_ufactor <= 0.080
        table_4a_wall_group = 'H'
      elsif wall_ufactor <= 0.108
        table_4a_wall_group = 'G'
      elsif wall_ufactor <= 0.148
        table_4a_wall_group = 'F'
      else
        table_4a_wall_group = 'E'
      end

    elsif [HPXML::WallTypeBrick, HPXML::WallTypeAdobe, HPXML::WallTypeConcrete].include? wall_type
      # Two Courses Brick or 8 Inches Concrete
      if wall_ufactor >= (0.218 + 0.179) / 2
        table_4a_wall_group = 'G'
      elsif wall_ufactor >= (0.152 + 0.132) / 2
        table_4a_wall_group = 'H'
      elsif wall_ufactor >= (0.117 + 0.079) / 2
        table_4a_wall_group = 'I'
      elsif wall_ufactor >= 0.079
        table_4a_wall_group = 'J'
      else
        table_4a_wall_group = 'K'
      end

    elsif wall_type == HPXML::WallTypeLog
      # Stacked Logs
      if wall_ufactor >= (0.103 + 0.091) / 2
        table_4a_wall_group = 'G'
      elsif wall_ufactor >= (0.091 + 0.082) / 2
        table_4a_wall_group = 'H'
      elsif wall_ufactor >= (0.074 + 0.068) / 2
        table_4a_wall_group = 'I'
      elsif wall_ufactor >= (0.068 + 0.063) / 2
        table_4a_wall_group = 'J'
      else
        table_4a_wall_group = 'K'
      end

    elsif [HPXML::WallTypeICF, HPXML::WallTypeStrawBale, HPXML::WallTypeStone].include? wall_type
      table_4a_wall_group = 'K'

    end

    # Mapping from Figure A12-12
    ashrae_wall_group = { 'A' => 'G', 'B' => 'F-G', 'C' => 'F', 'D' => 'E-F',
                          'E' => 'E', 'F' => 'D-E', 'G' => 'D', 'H' => 'C-D',
                          'I' => 'C', 'J' => 'B-C', 'K' => 'B' }[table_4a_wall_group]
    fail "Unexpected Table 4A wall group: #{table_4a_wall_group}" if ashrae_wall_group.nil?

    return ashrae_wall_group
  end

  # return ACH lookup values from Manual J Table 5A & Table 5B based on leakiness description
  #
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param leakiness_description [String] Leakiness description to look up the infiltration ach value
  # @param cfa [Double] Conditioned floor area in the dwelling unit (ft2)
  # @return [Array<Float, Float>] Heating and cooling ACH values from Manual J Table 5A/5B
  def self.get_mj_default_ach_values(hpxml_bldg, leakiness_description, cfa)
    ncfl_ag = hpxml_bldg.building_construction.number_of_conditioned_floors_above_grade
    # Manual J Table 5A
    ach_table_sfd_htg = [
      # single story
      { HPXML::LeakinessVeryTight => [0.21, 0.16, 0.14, 0.11, 0.10],
        HPXML::LeakinessTight => [0.41, 0.31, 0.26, 0.22, 0.19],
        HPXML::LeakinessAverage => [0.61, 0.45, 0.38, 0.32, 0.28],
        HPXML::LeakinessLeaky => [0.95, 0.70, 0.59, 0.49, 0.43],
        HPXML::LeakinessVeryLeaky => [1.29, 0.94, 0.80, 0.66, 0.58] },
      # two story
      { HPXML::LeakinessVeryTight => [0.27, 0.20, 0.18, 0.15, 0.13],
        HPXML::LeakinessTight => [0.53, 0.39, 0.34, 0.28, 0.25],
        HPXML::LeakinessAverage => [0.79, 0.58, 0.50, 0.41, 0.37],
        HPXML::LeakinessLeaky => [1.23, 0.90, 0.77, 0.63, 0.56],
        HPXML::LeakinessVeryLeaky => [1.67, 1.22, 1.04, 0.85, 0.75] }
    ]
    ach_table_sfd_clg = [
      # single story
      { HPXML::LeakinessVeryTight => [0.11, 0.08, 0.07, 0.06, 0.05],
        HPXML::LeakinessTight => [0.22, 0.16, 0.14, 0.11, 0.10],
        HPXML::LeakinessAverage => [0.32, 0.23, 0.20, 0.16, 0.15],
        HPXML::LeakinessLeaky => [0.50, 0.36, 0.31, 0.25, 0.23],
        HPXML::LeakinessVeryLeaky => [0.67, 0.49, 0.42, 0.34, 0.30] },
      # two story
      { HPXML::LeakinessVeryTight => [0.14, 0.11, 0.09, 0.08, 0.07],
        HPXML::LeakinessTight => [0.28, 0.21, 0.18, 0.15, 0.13],
        HPXML::LeakinessAverage => [0.41, 0.30, 0.26, 0.21, 0.19],
        HPXML::LeakinessLeaky => [0.64, 0.47, 0.40, 0.33, 0.29],
        HPXML::LeakinessVeryLeaky => [0.87, 0.64, 0.54, 0.44, 0.39] }
    ]
    # Manual J Table 5B
    ach_table_mf_htg = { HPXML::LeakinessVeryTight => [0.24, 0.18, 0.15, 0.13, 0.12],
                         HPXML::LeakinessTight => [0.47, 0.34, 0.29, 0.25, 0.22],
                         HPXML::LeakinessAverage => [0.69, 0.50, 0.43, 0.36, 0.32],
                         HPXML::LeakinessLeaky => [1.08, 0.78, 0.67, 0.55, 0.49],
                         HPXML::LeakinessVeryLeaky => [1.46, 1.06, 0.91, 0.74, 0.65] }
    ach_table_mf_clg = { HPXML::LeakinessVeryTight => [0.13, 0.09, 0.08, 0.07, 0.06],
                         HPXML::LeakinessTight => [0.25, 0.18, 0.16, 0.13, 0.12],
                         HPXML::LeakinessAverage => [0.36, 0.27, 0.23, 0.19, 0.17],
                         HPXML::LeakinessLeaky => [0.57, 0.42, 0.36, 0.29, 0.26],
                         HPXML::LeakinessVeryLeaky => [0.77, 0.56, 0.48, 0.39, 0.34] }
    groupings = [lambda { |v| v <= 900.0 },
                 lambda { |v| v > 900.0 && v <= 1500.0 },
                 lambda { |v| v > 1500.0 && v <= 2000.0 },
                 lambda { |v| v > 2000.0 && v <= 3000.0 },
                 lambda { |v| v > 3000.0 }]
    index = nil
    groupings.each_with_index do |fn, i|
      if fn.call(cfa)
        index = i
        break
      end
    end

    if hpxml_bldg.building_construction.residential_facility_type == HPXML::ResidentialTypeSFD
      if ncfl_ag < 2
        ach_htg = ach_table_sfd_htg[0][leakiness_description][index]
        ach_clg = ach_table_sfd_clg[0][leakiness_description][index]
      else
        ach_htg = ach_table_sfd_htg[1][leakiness_description][index]
        ach_clg = ach_table_sfd_clg[1][leakiness_description][index]
      end
    else
      ach_htg = ach_table_mf_htg[leakiness_description][index]
      ach_clg = ach_table_mf_clg[leakiness_description][index]
    end
    return ach_htg, ach_clg
  end

  # Calculates a crude approximation for the average R-value of a set of surfaces.
  #
  # @param surfaces [Array<OpenStudio::Model::Surface>] array of OpenStudio::Model::Surface objects
  # @return [Double] Average R-value (hr-ft2-F/Btu)
  def self.calculate_average_r_value(surfaces)
    surfaces_a = 0.0
    surfaces_ua = 0.0
    surfaces.each do |surface|
      surfaces_a += surface.area
      if not surface.insulation_assembly_r_value.nil?
        surfaces_ua += (1.0 / surface.insulation_assembly_r_value) * surface.area
      else
        surfaces_ua += (1.0 / (surface.insulation_interior_r_value + surface.insulation_exterior_r_value)) * surface.area
      end
    end
    return surfaces_a / surfaces_ua
  end

  # Calculates the foundation wall effective U-factor according to Manual J Section A12-4.
  #
  # @param foundation_wall [HPXML::FoundationWall] The foundation wall of interest
  # @param include_soil [Boolean] Whether to include the thermal resistance of soil in the calculation
  # @param ground_conductivity [Double] Ground conductivity (Btu/hr-ft-F)
  # @return [Double] U-factor for the foundation wall (Btu/hr-ft2-F)
  def self.get_foundation_wall_ufactor(foundation_wall, include_soil, ground_conductivity)
    # Calculate effective U-factor

    if not foundation_wall.insulation_assembly_r_value.nil?
      wall_constr_rvalue = foundation_wall.insulation_assembly_r_value - Material.AirFilmVertical.rvalue
      wall_ins_rvalue_int, wall_ins_rvalue_ext = 0, 0
      wall_ins_dist_to_top_int, wall_ins_dist_to_top_ext = 0, 0
      wall_ins_dist_to_bottom_int, wall_ins_dist_to_bottom_ext = 0, 0
    else
      wall_constr_rvalue = Material.Concrete(foundation_wall.thickness).rvalue
      wall_ins_rvalue_int = foundation_wall.insulation_interior_r_value
      wall_ins_rvalue_ext = foundation_wall.insulation_exterior_r_value
      wall_ins_dist_to_top_int = foundation_wall.insulation_interior_distance_to_top
      wall_ins_dist_to_top_ext = foundation_wall.insulation_exterior_distance_to_top
      wall_ins_dist_to_bottom_int = foundation_wall.insulation_interior_distance_to_bottom
      wall_ins_dist_to_bottom_ext = foundation_wall.insulation_exterior_distance_to_bottom
    end

    u_wall = 0.0
    wall_height = foundation_wall.height.ceil
    wall_depth_above_grade = foundation_wall.height - foundation_wall.depth_below_grade
    for distance_to_top in 1..wall_height
      # Calculate R-wall at this depth
      r_wall = wall_constr_rvalue + Material.AirFilmVertical.rvalue # Base wall construction + interior film
      if distance_to_top <= wall_depth_above_grade
        # Above-grade: no soil, add exterior film
        r_soil = 0.0
        r_wall += Material.AirFilmOutside.rvalue
      else
        # Below-grade: add soil, no exterior film
        distance_to_grade = distance_to_top - wall_depth_above_grade
        r_soil = (Math::PI * distance_to_grade / 2.0) / ground_conductivity
      end
      if (distance_to_top > wall_ins_dist_to_top_int) && (distance_to_top <= wall_ins_dist_to_bottom_int)
        r_wall += wall_ins_rvalue_int # Interior insulation at this depth, add R-value
      end
      if (distance_to_top > wall_ins_dist_to_top_ext) && (distance_to_top <= wall_ins_dist_to_bottom_ext)
        r_wall += wall_ins_rvalue_ext # Exterior insulation at this depth, add R-value
      end
      if include_soil
        u_wall += 1.0 / (r_soil + r_wall)
      else
        u_wall += 1.0 / r_wall
      end
    end
    u_wall /= wall_height
    if include_soil
      u_wall *= 0.85 # 15% decrease due to soil thermal storage per Manual J
    end

    return u_wall
  end

  # Calculates the slab F-value according to Manual J Section A12-8.
  #
  # @param slab [HPXML::Slab] The slab of interest
  # @param ground_conductivity [Double] Ground conductivity (Btu/hr-ft-F)
  # @return [Double] F-value for the slab (Btu/ft-F)
  def self.calc_slab_f_value(slab, ground_conductivity)
    soil_r_per_foot = 1.0 / ground_conductivity

    slab_r_gravel_per_inch = 0.65 # Based on calibration to Table 4A values by Tony Fontanini

    # Because of uncertainty pertaining to the effective path radius, F-values are calculated
    # for six radii (8, 9, 10, 11, 12, and 13 feet) and averaged.
    f_values = []
    for path_radius in 8..13
      u_effective = []
      for radius in 0..path_radius
        spl = [Math::PI * radius - 1, 0].max # soil path length (SPL)

        # Concrete, gravel, and insulation
        if radius == 0
          r_concrete = 0.0
          r_gravel = 0.0 # No gravel on edge
          if slab.perimeter_insulation_depth > 0
            r_ins = slab.perimeter_insulation_r_value # Insulation on edge
          else
            r_ins = 0.0
          end
        else
          r_concrete = Material.Concrete(slab.thickness).rvalue
          r_gravel = [slab_r_gravel_per_inch * (12.0 - slab.thickness), 0].max
          if slab.under_slab_insulation_spans_entire_slab
            r_ins = slab.under_slab_insulation_r_value
          elsif radius <= slab.under_slab_insulation_width && radius <= slab.perimeter_insulation_depth
            r_ins = slab.under_slab_insulation_r_value + slab.perimeter_insulation_r_value
          elsif radius <= slab.under_slab_insulation_width
            r_ins = slab.under_slab_insulation_r_value
          elsif radius <= slab.perimeter_insulation_depth
            r_ins = slab.perimeter_insulation_r_value
          else
            r_ins = 0.0
          end
        end

        # Air Films = Indoor Finish + Indoor Air Film + Exposed Air Film (Figure A12-6 pg. 517)
        r_air_film = 0.05 + 0.92 + 0.17

        # Soil
        r_soil = soil_r_per_foot * spl # (h-F-ft2/BTU)

        # Effective R-Value
        r_air_to_air = r_concrete + r_gravel + r_ins + r_air_film + r_soil

        # Effective U-Factor
        u_effective << 1.0 / r_air_to_air
      end

      f_values << u_effective.sum
    end

    return f_values.sum() / f_values.size
  end

  # Calculates the basement slab U-factor according to Manual J Section A12-7 and
  # ASHRAE HoF 2013 pg 18.31 Eq 40.
  #
  # @param slab_is_insulated [Boolean] Whether the slab is insulated
  # @param depth_below_grade [Double] Depth of the slab below-grade (ft)
  # @param width_of_shortest_side [Double] Width of the shortest side of the slab
  # @param ground_conductivity [Double] Ground conductivity (Btu/hr-ft-F)
  # @return [Double] U-factor for the basement slab (Btu/hr-ft2-F)
  def self.calc_basement_slab_ufactor(slab_is_insulated, depth_below_grade, width_of_shortest_side, ground_conductivity)
    r_other = 1.47 # Value from ASHRAE HoF, probably used by Manual J
    z_f = depth_below_grade
    w_b = width_of_shortest_side
    u_avg_bf = (2.0 * ground_conductivity / (Math::PI * w_b)) * (Math::log(w_b / 2.0 + z_f / 2.0 + (ground_conductivity * r_other) / Math::PI) - Math::log(z_f / 2.0 + (ground_conductivity * r_other) / Math::PI))
    u_value = 0.85 * u_avg_bf # To account for the storage effect of soil, multiply by 0.85
    if slab_is_insulated
      u_value *= 0.7 # U-values are multiplied by 0.70 to produce U-values for insulated floors
    end
    return u_value
  end

  # Gets the system type of the specified HPXML heating system.
  #
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @return [string] Heating system type (e.g., HPXML::HVACTypeFurnace or HPXML::HVACTypeHeatPumpAirToAir) or nil
  def self.get_hvac_heating_type(hvac_heating)
    if hvac_heating.nil?
      return
    elsif hvac_heating.is_a? HPXML::HeatingSystem
      return hvac_heating.heating_system_type
    else
      return hvac_heating.heat_pump_type
    end
  end

  # Gets the system type of the specified HPXML cooling system.
  #
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @return [string] Cooling system type (e.g., HPXML::HVACTypeCentralAirConditioner or HPXML::HVACTypeHeatPumpAirToAir) or nil
  def self.get_hvac_cooling_type(hvac_cooling)
    if hvac_cooling.nil?
      return
    elsif hvac_cooling.is_a? HPXML::CoolingSystem
      return hvac_cooling.cooling_system_type
    else
      return hvac_cooling.heat_pump_type
    end
  end

  # Calculates the fraction of zone heating/cooling design loads served by a single HVAC system. This accounts
  # for two situations:
  # 1. There is a single conditioned zone, in which case the HVAC system may be meeting the entire load or may
  #    be meeting a portion of the load (e.g., room ACs serving 30% of the home). In this case, we use the
  #    FractionHeadLoadServed/FractionCoolLoadServed inputs.
  # 2. There are multiple conditioned zones, in which case we assume the HVAC system(s) attached to it fully
  #    condition the zone. If there are multiple HVAC systems serving the zone, we apportion the zone load
  #    to each HVAC system using the FractionHeadLoadServed/FractionCoolLoadServed inputs.
  #
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param hvac_systems [Array<Hash>] List of HPXML HVAC (heating and/or cooling) systems
  # @param zone [HPXML::Zone] The current zone of interest
  # @return [Array<Double, Double>] Fraction of zone heat load, fraction of zone cool load
  def self.get_fractions_load_served(hvac_heating, hvac_cooling, hpxml_bldg, hvac_systems, zone)
    if hvac_cooling.is_a?(HPXML::CoolingSystem) && hvac_cooling.has_integrated_heating
      frac_heat_load_served = hvac_cooling.integrated_heating_system_fraction_heat_load_served
    elsif hvac_heating.nil?
      frac_heat_load_served = 0
    elsif hvac_heating.is_a?(HPXML::HeatingSystem) && hvac_heating.is_heat_pump_backup_system
      if not hvac_systems.nil?
        # Use the same load fractions as the heat pump
        heat_pump = hvac_heating.primary_heat_pump
        frac_heat_load_served = heat_pump.fraction_heat_load_served
      else
        frac_heat_load_served = 0 # Don't double count the HP and HP backup when calculating the fraction for the zone
      end
    else
      frac_heat_load_served = hvac_heating.fraction_heat_load_served
    end

    if hvac_cooling.nil?
      frac_cool_load_served = 0
    else
      frac_cool_load_served = hvac_cooling.fraction_cool_load_served
    end

    if hpxml_bldg.conditioned_zones.size == 1
      # One conditioned zone, use the heating/cooling fractions as provided.
    else
      # There are multiple conditioned zones, so assume the HVAC systems attached to
      # the zone fully conditions it. Determine the fraction of the zone load each
      # HVAC system serves by dividing (fraction load served by this system) by
      # (fraction load served by all the zone's systems).
      if not hvac_systems.nil?
        sum_frac_heat_load_served = 0.0
        sum_frac_cool_load_served = 0.0
        hvac_systems.each do |hvac_system2|
          hvac_heating2, hvac_cooling2 = hvac_system2[:heating], hvac_system2[:cooling]
          zone2 = hvac_heating2.nil? ? hvac_cooling2.zone : hvac_heating2.zone
          next if is_system_to_skip(hvac_heating2, hvac_cooling2, zone)
          next if zone2 != zone

          fracs = get_fractions_load_served(hvac_heating2, hvac_cooling2, hpxml_bldg, nil, nil)
          sum_frac_heat_load_served += fracs[0]
          sum_frac_cool_load_served += fracs[1]
        end

        if sum_frac_heat_load_served > 0
          frac_heat_load_served /= sum_frac_heat_load_served
        end
        if sum_frac_cool_load_served > 0
          frac_cool_load_served /= sum_frac_cool_load_served
        end
      end
    end

    return frac_heat_load_served, frac_cool_load_served
  end

  # Determines whether the HPXML Zone has radiant floor heating.
  #
  # @param zone [HPXML::Zone] The current zone of interest
  # @return [Boolean] Presence of radiant floors
  def self.get_has_radiant_floor(zone)
    # FUTURE: Allow specifying presence of radiant floors on a floor-by-floor basis?
    if zone.heating_systems.count { |htg| htg.electric_resistance_distribution == HPXML::ElectricResistanceDistributionRadiantFloor } > 0
      return true
    end
    if zone.hvac_distributions.count { |hvac_dist| hvac_dist.hydronic_type == HPXML::HydronicTypeRadiantFloor } > 0
      return true
    end

    return false
  end

  # Assigns the final calculated capacities, airflows, etc. to the HPXML HVAC system.
  # These values will end up in the in.xml file, among other outputs.
  #
  # @param hvac_heating [HPXML::HeatingSystem or HPXML::HeatPump] The heating portion of the current HPXML HVAC system
  # @param hvac_cooling [HPXML::CoolingSystem or HPXML::HeatPump] The cooling portion of the current HPXML HVAC system
  # @param hvac_sizings [HVACSizingValues] Object with sizing values for a given HVAC system
  # @return [void]
  def self.assign_to_hpxml_system(hvac_heating, hvac_cooling, hvac_sizings)
    if not hvac_heating.nil?

      # Heating capacity
      if hvac_heating.heating_capacity.nil? || ((hvac_heating.heating_capacity - hvac_sizings.Heat_Capacity).abs >= 1.0)
        scaling_factor = Float(hvac_sizings.Heat_Capacity.round) / hvac_heating.heating_capacity unless hvac_heating.heating_capacity.nil?
        # Heating capacity @ 17F
        if hvac_heating.is_a? HPXML::HeatPump
          if (not hvac_heating.heating_capacity.nil?) && (not hvac_heating.heating_capacity_17F.nil?)
            # Fixed value entered; scale w/ heating_capacity in case allow_increased_fixed_capacities=true
            htg_cap_17f = hvac_heating.heating_capacity_17F * scaling_factor
            if (hvac_heating.heating_capacity_17F - htg_cap_17f).abs >= 1.0
              hvac_heating.heating_capacity_17F = Float(htg_cap_17f.round)
              hvac_heating.heating_capacity_17F_isdefaulted = true
            end
          end
        end
        if not hvac_heating.heating_detailed_performance_data.empty?
          # Fixed values entered; Scale w/ heating_capacity in case allow_increased_fixed_capacities=true
          hvac_heating.heating_detailed_performance_data.each do |dp|
            next if dp.capacity.nil? # using autosized values, process later

            htg_cap_dp = dp.capacity * scaling_factor
            if (dp.capacity - htg_cap_dp).abs >= 1.0
              dp.capacity = Float(htg_cap_dp.round)
              dp.capacity_isdefaulted = true
            end
          end
        end
        hvac_heating.heating_capacity = Float(hvac_sizings.Heat_Capacity.round)
        hvac_heating.heating_capacity_isdefaulted = true
      end

      # Heating backup capacity
      if hvac_heating.is_a? HPXML::HeatPump
        if hvac_heating.backup_type.nil?
          if hvac_heating.backup_heating_capacity.nil?
            hvac_heating.backup_heating_capacity = 0.0
            hvac_heating.backup_heating_capacity_isdefaulted = true
          end
        elsif hvac_heating.backup_type == HPXML::HeatPumpBackupTypeIntegrated
          if hvac_heating.backup_heating_capacity.nil? || ((hvac_heating.backup_heating_capacity - hvac_sizings.Heat_Capacity_Supp).abs >= 1.0)
            hvac_heating.backup_heating_capacity = Float(hvac_sizings.Heat_Capacity_Supp.round)
            hvac_heating.backup_heating_capacity_isdefaulted = true
          end
        end
      end

      # Heating airflow
      if not (hvac_heating.is_a?(HPXML::HeatingSystem) &&
              [HPXML::HVACTypeBoiler,
               HPXML::HVACTypeElectricResistance].include?(hvac_heating.heating_system_type))
        hvac_heating.heating_airflow_cfm = Float(hvac_sizings.Heat_Airflow.round)
        hvac_heating.heating_airflow_cfm_isdefaulted = true
      end

      # Heating geothermal loop
      if hvac_heating.is_a? HPXML::HeatPump
        hvac_heating.additional_properties.GSHP_G_Functions = hvac_sizings.GSHP_G_Functions

        geothermal_loop = hvac_heating.geothermal_loop
        if not geothermal_loop.nil?
          if geothermal_loop.loop_flow.nil?
            geothermal_loop.loop_flow = hvac_sizings.GSHP_Loop_Flow
            geothermal_loop.loop_flow_isdefaulted = true
          end
          if geothermal_loop.num_bore_holes.nil?
            geothermal_loop.num_bore_holes = hvac_sizings.GSHP_Bore_Holes
            geothermal_loop.num_bore_holes_isdefaulted = true
          end
          if geothermal_loop.bore_length.nil?
            geothermal_loop.bore_length = hvac_sizings.GSHP_Bore_Depth
            geothermal_loop.bore_length_isdefaulted = true
          end
          if geothermal_loop.bore_config.nil?
            geothermal_loop.bore_config = hvac_sizings.GSHP_Bore_Config
            geothermal_loop.bore_config_isdefaulted = true
          end
        end
      end

    end

    if not hvac_cooling.nil?

      # Cooling capacity
      if hvac_cooling.cooling_capacity.nil? || ((hvac_cooling.cooling_capacity - hvac_sizings.Cool_Capacity).abs >= 1.0)
        if not hvac_cooling.cooling_detailed_performance_data.empty?
          scaling_factor = Float(hvac_sizings.Cool_Capacity.round) / hvac_cooling.cooling_capacity unless hvac_cooling.cooling_capacity.nil?
          # Fixed values entered; Scale w/ cooling_capacity in case allow_increased_fixed_capacities=true
          hvac_cooling.cooling_detailed_performance_data.each do |dp|
            next if dp.capacity.nil? # using autosized values

            clg_cap_dp = dp.capacity * scaling_factor
            if (dp.capacity - clg_cap_dp).abs >= 1.0
              dp.capacity = Float(clg_cap_dp.round)
              dp.capacity_isdefaulted = true
            end
          end
        end
        hvac_cooling.cooling_capacity = Float(hvac_sizings.Cool_Capacity.round)
        hvac_cooling.cooling_capacity_isdefaulted = true
      end

      # Cooling integrated heating system capacity
      if (hvac_cooling.is_a? HPXML::CoolingSystem) && hvac_cooling.has_integrated_heating
        if hvac_cooling.integrated_heating_system_capacity.nil? || ((hvac_cooling.integrated_heating_system_capacity - hvac_sizings.Heat_Capacity).abs >= 1.0)
          hvac_cooling.integrated_heating_system_capacity = Float(hvac_sizings.Heat_Capacity.round)
          hvac_cooling.integrated_heating_system_capacity_isdefaulted = true
        end
        hvac_cooling.integrated_heating_system_airflow_cfm = Float(hvac_sizings.Heat_Airflow.round)
        hvac_cooling.integrated_heating_system_airflow_cfm_isdefaulted = true
      end
      hvac_cooling.additional_properties.cooling_capacity_sensible = Float(hvac_sizings.Cool_Capacity_Sens.round)

      # Cooling airflow
      hvac_cooling.cooling_airflow_cfm = Float(hvac_sizings.Cool_Airflow.round)
      hvac_cooling.cooling_airflow_cfm_isdefaulted = true
    end
  end

  # Sums all the zone loads to calculate the entire building's loads.
  #
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @return [DesignLoadValues] Building loads
  def self.aggregate_zone_loads_to_bldg(all_zone_loads)
    bldg_loads = DesignLoadValues.new
    all_zone_loads.values.each do |zone_load|
      bldg_loads.Cool_Sens += zone_load.Cool_Sens
      bldg_loads.Cool_Lat += zone_load.Cool_Lat
      bldg_loads.Cool_Tot += zone_load.Cool_Tot
      bldg_loads.Cool_Ducts_Sens += zone_load.Cool_Ducts_Sens
      bldg_loads.Cool_Ducts_Lat += zone_load.Cool_Ducts_Lat
      bldg_loads.Cool_Windows += zone_load.Cool_Windows
      bldg_loads.Cool_Skylights += zone_load.Cool_Skylights
      bldg_loads.Cool_Doors += zone_load.Cool_Doors
      bldg_loads.Cool_Walls += zone_load.Cool_Walls
      bldg_loads.Cool_Roofs += zone_load.Cool_Roofs
      bldg_loads.Cool_Floors += zone_load.Cool_Floors
      bldg_loads.Cool_Slabs += zone_load.Cool_Slabs
      bldg_loads.Cool_Ceilings += zone_load.Cool_Ceilings
      bldg_loads.Cool_Infil_Sens += zone_load.Cool_Infil_Sens
      bldg_loads.Cool_Vent_Sens += zone_load.Cool_Vent_Sens
      bldg_loads.Cool_Infil_Lat += zone_load.Cool_Infil_Lat
      bldg_loads.Cool_Vent_Lat += zone_load.Cool_Vent_Lat
      bldg_loads.Cool_IntGains_Sens += zone_load.Cool_IntGains_Sens
      bldg_loads.Cool_IntGains_Lat += zone_load.Cool_IntGains_Lat
      bldg_loads.Cool_BlowerHeat += zone_load.Cool_BlowerHeat
      bldg_loads.Cool_AEDExcursion += zone_load.Cool_AEDExcursion
      bldg_loads.Heat_Tot += zone_load.Heat_Tot
      bldg_loads.Heat_Ducts += zone_load.Heat_Ducts
      bldg_loads.Heat_Windows += zone_load.Heat_Windows
      bldg_loads.Heat_Skylights += zone_load.Heat_Skylights
      bldg_loads.Heat_Doors += zone_load.Heat_Doors
      bldg_loads.Heat_Walls += zone_load.Heat_Walls
      bldg_loads.Heat_Roofs += zone_load.Heat_Roofs
      bldg_loads.Heat_Floors += zone_load.Heat_Floors
      bldg_loads.Heat_Slabs += zone_load.Heat_Slabs
      bldg_loads.Heat_Ceilings += zone_load.Heat_Ceilings
      bldg_loads.Heat_Infil += zone_load.Heat_Infil
      bldg_loads.Heat_Vent += zone_load.Heat_Vent
      bldg_loads.Heat_Piping += zone_load.Heat_Piping
      zone_load.HourlyFenestrationLoads.each_with_index do |load, i|
        bldg_loads.HourlyFenestrationLoads[i] += load
      end
    end
    return bldg_loads
  end

  # Assigns the final design loads to the given HPXML object. For example,
  # assigns space design loads to an HPXML Space, or assigns building design
  # loads to the HPXML Building's HVACPlant.
  #
  # @param hpxml_object [HPXML::HVACPlant or HPXML::Zone or HPXML::Space] HPXML object to assign the loads to
  # @param loads [DesignLoadValues] Design loads for the building, zone, or space
  # @return [void]
  def self.assign_to_hpxml_obj(hpxml_object, loads)
    tol = 10 # Btu/hr

    # Assign heating design loads to HPXML object
    hpxml_object.hdl_total = Float(loads.Heat_Tot.round)
    hpxml_object.hdl_walls = Float(loads.Heat_Walls.round)
    hpxml_object.hdl_ceilings = Float(loads.Heat_Ceilings.round)
    hpxml_object.hdl_roofs = Float(loads.Heat_Roofs.round)
    hpxml_object.hdl_floors = Float(loads.Heat_Floors.round)
    hpxml_object.hdl_slabs = Float(loads.Heat_Slabs.round)
    hpxml_object.hdl_windows = Float(loads.Heat_Windows.round)
    hpxml_object.hdl_skylights = Float(loads.Heat_Skylights.round)
    hpxml_object.hdl_doors = Float(loads.Heat_Doors.round)
    hpxml_object.hdl_infil = Float(loads.Heat_Infil.round)
    hpxml_object.hdl_vent = Float(loads.Heat_Vent.round)
    hpxml_object.hdl_piping = Float(loads.Heat_Piping.round)
    hpxml_object.hdl_ducts = Float(loads.Heat_Ducts.round)
    if hpxml_object.hdl_total != 0
      # Error-checking to ensure we captured all the design load components
      hdl_sum = (hpxml_object.hdl_walls + hpxml_object.hdl_ceilings + hpxml_object.hdl_roofs +
                 hpxml_object.hdl_floors + hpxml_object.hdl_slabs + hpxml_object.hdl_windows +
                 hpxml_object.hdl_skylights + hpxml_object.hdl_doors + hpxml_object.hdl_infil +
                 hpxml_object.hdl_vent + hpxml_object.hdl_piping + hpxml_object.hdl_ducts)
      if (hdl_sum - hpxml_object.hdl_total).abs > tol
        fail 'Heating design loads do not sum to total.'
      end
    end

    # Assign cooling sensible design loads to HPXML object
    hpxml_object.cdl_sens_total = Float(loads.Cool_Sens.round)
    hpxml_object.cdl_sens_walls = Float(loads.Cool_Walls.round)
    hpxml_object.cdl_sens_ceilings = Float(loads.Cool_Ceilings.round)
    hpxml_object.cdl_sens_roofs = Float(loads.Cool_Roofs.round)
    hpxml_object.cdl_sens_floors = Float(loads.Cool_Floors.round)
    hpxml_object.cdl_sens_slabs = Float(loads.Cool_Slabs.round)
    hpxml_object.cdl_sens_windows = Float(loads.Cool_Windows.round)
    hpxml_object.cdl_sens_skylights = Float(loads.Cool_Skylights.round)
    hpxml_object.cdl_sens_aedexcursion = Float(loads.Cool_AEDExcursion.round)
    hpxml_object.cdl_sens_doors = Float(loads.Cool_Doors.round)
    hpxml_object.cdl_sens_infil = Float(loads.Cool_Infil_Sens.round)
    hpxml_object.cdl_sens_vent = Float(loads.Cool_Vent_Sens.round)
    hpxml_object.cdl_sens_ducts = Float(loads.Cool_Ducts_Sens.round)
    hpxml_object.cdl_sens_intgains = Float(loads.Cool_IntGains_Sens.round)
    hpxml_object.cdl_sens_blowerheat = Float(loads.Cool_BlowerHeat.round)
    hpxml_object.cdl_sens_aed_curve = loads.HourlyFenestrationLoads.map { |f| f.round }.join(', ')
    if hpxml_object.cdl_sens_total != 0
      # Error-checking to ensure we captured all the design load components
      cdl_sens_sum = (hpxml_object.cdl_sens_walls + hpxml_object.cdl_sens_ceilings +
                      hpxml_object.cdl_sens_roofs + hpxml_object.cdl_sens_floors +
                      hpxml_object.cdl_sens_slabs + hpxml_object.cdl_sens_windows +
                      hpxml_object.cdl_sens_skylights + hpxml_object.cdl_sens_doors +
                      hpxml_object.cdl_sens_infil + hpxml_object.cdl_sens_vent +
                      hpxml_object.cdl_sens_ducts + hpxml_object.cdl_sens_intgains +
                      hpxml_object.cdl_sens_blowerheat + hpxml_object.cdl_sens_aedexcursion)
      if (cdl_sens_sum - hpxml_object.cdl_sens_total).abs > tol
        fail 'Cooling sensible design loads do not sum to total.'
      end
    end

    # Assign cooling latent design loads to HPXML object
    hpxml_object.cdl_lat_total = Float(loads.Cool_Lat.round)
    hpxml_object.cdl_lat_ducts = Float(loads.Cool_Ducts_Lat.round)
    hpxml_object.cdl_lat_infil = Float(loads.Cool_Infil_Lat.round)
    hpxml_object.cdl_lat_vent = Float(loads.Cool_Vent_Lat.round)
    hpxml_object.cdl_lat_intgains = Float(loads.Cool_IntGains_Lat.round)
    if hpxml_object.cdl_lat_total != 0
      # Error-checking to ensure we captured all the design load components
      cdl_lat_sum = (hpxml_object.cdl_lat_ducts + hpxml_object.cdl_lat_infil +
                     hpxml_object.cdl_lat_vent + hpxml_object.cdl_lat_intgains)
      if (cdl_lat_sum - hpxml_object.cdl_lat_total).abs > tol
        fail 'Cooling latent design loads do not sum to total.'
      end
    end
  end

  # Writes a output file with additional detailed information needed to fill out, e.g., an ACCA Form J1.
  #
  # @param output_format [String] Detailed output file format ('csv', 'json', or 'msgpack')
  # @param output_file_path [String] Detailed output file path
  # @param hpxml_bldg [HPXML::Building] HPXML Building object representing an individual dwelling unit
  # @param all_zone_loads [Hash] Map of HPXML::Zones => DesignLoadValues object
  # @param all_space_loads [Hash] Map of HPXML::Spaces => DesignLoadValues object
  # @return [void]
  def self.write_detailed_output(output_format, output_file_path, hpxml_bldg, all_zone_loads, all_space_loads)
    line_break = nil
    results_out = []

    orientation_map = { HPXML::OrientationEast => 'E',
                        HPXML::OrientationNorth => 'N',
                        HPXML::OrientationNortheast => 'NE',
                        HPXML::OrientationNorthwest => 'NW',
                        HPXML::OrientationSouth => 'S',
                        HPXML::OrientationSoutheast => 'SE',
                        HPXML::OrientationSouthwest => 'SW',
                        HPXML::OrientationWest => 'W' }

    # Gets the HPXML Windows that should be output for the building, zone, or space.
    #
    # @param obj [HPXML::Building or HPXML::Zone or HPXML::Space] The HPXML building, zone, or space of interest
    # @return [Array] List of windows
    def self.windows(obj)
      return obj.windows.select { |s| s.additional_properties.respond_to?(:detailed_output_values) }
    end

    # Gets the HPXML Skylights that should be output for the building, zone, or space.
    #
    # @param obj [HPXML::Building or HPXML::Zone or HPXML::Space] The HPXML building, zone, or space of interest
    # @return [Array] List of skylights
    def self.skylights(obj)
      return obj.skylights.select { |s| s.additional_properties.respond_to?(:detailed_output_values) }
    end

    # Gets the HPXML Doors that should be output for the building, zone, or space.
    #
    # @param obj [HPXML::Building or HPXML::Zone or HPXML::Space] The HPXML building, zone, or space of interest
    # @return [Array] List of doors
    def self.doors(obj)
      return obj.doors.select { |s| s.additional_properties.respond_to?(:detailed_output_values) }
    end

    # Gets the HPXML Walls, RimJoists, and FoundationWalls that should be output for the building, zone, or space.
    #
    # @param obj [HPXML::Building or HPXML::Zone or HPXML::Space] The HPXML building, zone, or space of interest
    # @return [Array] List of walls/rim joists/foundation walls
    def self.walls(obj)
      return (obj.walls + obj.rim_joists + obj.foundation_walls).select { |s| s.additional_properties.respond_to?(:detailed_output_values) }
    end

    # Gets the HPXML Floors (ceilings) and Roofs that should be output for the building, zone, or space.
    #
    # @param obj [HPXML::Building or HPXML::Zone or HPXML::Space] The HPXML building, zone, or space of interest
    # @return [Array] List of ceilings/roofs
    def self.ceilings(obj)
      return obj.floors.select { |s| s.additional_properties.respond_to?(:detailed_output_values) && s.is_ceiling } + obj.roofs.select { |s| s.additional_properties.respond_to?(:detailed_output_values) }
    end

    # Gets the HPXML Floors (floors) and Slabs that should be output for the building, zone, or space.
    #
    # @param obj [HPXML::Building or HPXML::Zone or HPXML::Space] The HPXML building, zone, or space of interest
    # @return [Array] List of floors/slabs
    def self.floors(obj)
      return obj.floors.select { |s| s.additional_properties.respond_to?(:detailed_output_values) && s.is_floor } + obj.slabs.select { |s| s.additional_properties.respond_to?(:detailed_output_values) }
    end

    # Note: Every report name must have the HPXML BuildingID in it in case we are running a whole MF building with multiple Building elements.
    if hpxml_bldg.conditioned_zones[0].id.start_with?(Constants.AutomaticallyAdded)
      zone_col_names = ["#{hpxml_bldg.building_id}"] # Leave out name of automatically added zone
    else
      zone_col_names = all_zone_loads.keys.map { |zone| "#{hpxml_bldg.building_id}: #{zone.id}" }
    end
    if all_space_loads.empty?
      space_col_names = []
    else
      space_col_names = all_space_loads.keys.map { |space| "#{hpxml_bldg.building_id}: #{space.id}" }
    end

    # Summary Results
    results_out << ["Report: #{hpxml_bldg.building_id}: Summary", 'Orientation', 'Heating HTM', 'Cooling HTM', 'Heating CFM', 'Cooling CFM']
    windows(hpxml_bldg).each do |window|
      fj1 = window.additional_properties.detailed_output_values
      results_out << ["Windows: #{window.id}", orientation_map[window.orientation], fj1.Heat_HTM, fj1.Cool_HTM]
    end
    skylights(hpxml_bldg).each do |skylight|
      fj1 = skylight.additional_properties.detailed_output_values
      results_out << ["Skylights: #{skylight.id}", orientation_map[skylight.orientation], fj1.Heat_HTM, fj1.Cool_HTM]
    end
    doors(hpxml_bldg).each do |door|
      fj1 = door.additional_properties.detailed_output_values
      results_out << ["Doors: #{door.id}", orientation_map[door.orientation], fj1.Heat_HTM, fj1.Cool_HTM]
    end
    walls(hpxml_bldg).each do |wall|
      fj1 = wall.additional_properties.detailed_output_values
      results_out << ["Walls: #{wall.id}", orientation_map[wall.orientation], fj1.Heat_HTM, fj1.Cool_HTM]
    end
    ceilings(hpxml_bldg).each do |ceiling|
      fj1 = ceiling.additional_properties.detailed_output_values
      results_out << ["Ceilings: #{ceiling.id}", nil, fj1.Heat_HTM, fj1.Cool_HTM]
    end
    floors(hpxml_bldg).each do |floor|
      fj1 = floor.additional_properties.detailed_output_values
      results_out << ["Floors: #{floor.id}", nil, fj1.Heat_HTM, fj1.Cool_HTM]
    end
    results_out << ['Infiltration', nil, nil, nil, hpxml_bldg.additional_properties.infil_heat_cfm.round, hpxml_bldg.additional_properties.infil_cool_cfm.round]
    results_out << ['Ventilation', nil, nil, nil, hpxml_bldg.additional_properties.vent_heat_cfm.round, hpxml_bldg.additional_properties.vent_cool_cfm.round]

    # Zone results
    all_zone_loads.keys.each_with_index do |zone, i|
      results_out << [line_break]
      results_out << ["Report: #{zone_col_names[i]}: Loads", 'Area (ft^2)', 'Length (ft)', 'Wall Area Ratio', 'Heating (Btuh)', 'Cooling Sensible (Btuh)', 'Cooling Latent (Btuh)']
      windows(zone).each do |window|
        fj1 = window.additional_properties.detailed_output_values
        results_out << ["Windows: #{window.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      skylights(zone).each do |skylight|
        fj1 = skylight.additional_properties.detailed_output_values
        results_out << ["Skylights: #{skylight.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      doors(zone).each do |door|
        fj1 = door.additional_properties.detailed_output_values
        results_out << ["Doors: #{door.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      walls(zone).each do |wall|
        fj1 = wall.additional_properties.detailed_output_values
        results_out << ["Walls: #{wall.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      ceilings(zone).each do |ceiling|
        fj1 = ceiling.additional_properties.detailed_output_values
        results_out << ["Ceilings: #{ceiling.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      floors(zone).each do |floor|
        fj1 = floor.additional_properties.detailed_output_values
        results_out << ["Floors: #{floor.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      zone_loads = all_zone_loads[zone]
      results_out << ['Infiltration', nil, nil, 1.0, zone_loads.Heat_Infil.round, zone_loads.Cool_Infil_Sens.round, zone_loads.Cool_Infil_Lat.round]
      results_out << ['Internal Gains', nil, nil, nil, nil, zone_loads.Cool_IntGains_Sens.round, zone_loads.Cool_IntGains_Lat.round]
      results_out << ['Ducts', nil, nil, nil, zone_loads.Heat_Ducts.round, zone_loads.Cool_Ducts_Sens.round, zone_loads.Cool_Ducts_Lat.round]
      results_out << ['Ventilation', nil, nil, nil, zone_loads.Heat_Vent.round, zone_loads.Cool_Vent_Sens.round, zone_loads.Cool_Vent_Lat.round]
      results_out << ['Piping', nil, nil, nil, zone_loads.Heat_Piping.round]
      results_out << ['Blower Heat', nil, nil, nil, nil, zone_loads.Cool_BlowerHeat.round]
      results_out << ['AED Excursion', nil, nil, nil, nil, zone_loads.Cool_AEDExcursion.round]
      results_out << ['Total', nil, nil, nil, zone_loads.Heat_Tot.round, zone_loads.Cool_Sens.round, zone_loads.Cool_Lat.round]
    end

    # Space results
    all_space_loads.keys.each_with_index do |space, i|
      results_out << [line_break]
      results_out << ["Report: #{space_col_names[i]}: Loads", 'Area (ft^2)', 'Length (ft)', 'Wall Area Ratio', 'Heating (Btuh)', 'Cooling Sensible (Btuh)']
      windows(space).select { |s| s.wall.space == space }.each do |window|
        fj1 = window.additional_properties.detailed_output_values
        results_out << ["Windows: #{window.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      skylights(space).select { |s| s.roof.space == space }.each do |skylight|
        fj1 = skylight.additional_properties.detailed_output_values
        results_out << ["Skylights: #{skylight.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      doors(space).select { |s| s.wall.space == space }.each do |door|
        fj1 = door.additional_properties.detailed_output_values
        results_out << ["Doors: #{door.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      walls(space).select { |s| s.space == space }.each do |wall|
        fj1 = wall.additional_properties.detailed_output_values
        results_out << ["Walls: #{wall.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      ceilings(space).select { |s| s.space == space }.each do |ceiling|
        fj1 = ceiling.additional_properties.detailed_output_values
        results_out << ["Ceilings: #{ceiling.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      floors(space).select { |s| s.space == space }.each do |floor|
        fj1 = floor.additional_properties.detailed_output_values
        results_out << ["Floors: #{floor.id}", fj1.Area, fj1.Length, nil, fj1.Heat_Load, fj1.Cool_Load_Sens]
      end
      space_loads = all_space_loads[space]
      results_out << ['Infiltration', nil, nil, space.additional_properties.wall_area_ratio.round(3), space_loads.Heat_Infil.round, space_loads.Cool_Infil_Sens.round]
      results_out << ['Internal Gains', nil, nil, nil, nil, space_loads.Cool_IntGains_Sens.round]
      results_out << ['Ducts', nil, nil, nil, space_loads.Heat_Ducts.round, space_loads.Cool_Ducts_Sens.round]
      results_out << ['AED Excursion', nil, nil, nil, nil, space_loads.Cool_AEDExcursion.round]
      results_out << ['Total', nil, nil, nil, space_loads.Heat_Tot.round, space_loads.Cool_Sens.round]
    end

    # AED curve
    results_out << [line_break]
    results_out << ["Report: #{hpxml_bldg.building_id}: AED Curve"] + [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19].map { |hr| "Hr #{hr} (Btuh)" }
    all_zone_loads.values.each_with_index do |zone_loads, i|
      results_out << [zone_col_names[i]] + zone_loads.HourlyFenestrationLoads.map { |l| l.round }
    end
    all_space_loads.values.each_with_index do |space_loads, i|
      results_out << [space_col_names[i]] + space_loads.HourlyFenestrationLoads.map { |l| l.round }
    end

    if ['csv'].include? output_format
      if File.exist? output_file_path
        # Separate from existing data
        results_out.insert(0, [line_break])
      end
      CSV.open(output_file_path, 'a') { |csv| results_out.to_a.each { |elem| csv << elem } }
    elsif ['json', 'msgpack'].include? output_format
      h = {}
      report, columns = nil, nil
      results_out.each do |out|
        if out == [line_break]
          report, columns = nil, nil
          next
        end

        if report.nil? && out[0].start_with?('Report:')
          report = out[0]
          columns = out[1..-1]
          h[report] = {}
          next
        end

        name = out[0]
        items = {}
        for i in 1..out.size - 1
          next if out[i].nil?

          items[columns[i - 1]] = out[i]
        end
        h[report][name] = items
      end

      if File.exist? output_file_path
        h = JSON.parse(File.read(output_file_path)).merge(h)
      end

      if output_format == 'json'
        require 'json'
        File.open(output_file_path, 'w') { |json| json.write(JSON.pretty_generate(h)) }
      elsif output_format == 'msgpack'
        require 'msgpack'
        File.open(output_file_path, 'wb') { |json| h.to_msgpack(json) }
      end
    end
  end
end

# Object with a collection of misc Manual J values that are calculated up front.
class MJValues
  attr_accessor(:daily_range_temp_adjust, # [Double] CLTD adjustments based on daily temperature range (F)
                :daily_range_num,         # [Integer] Daily Temperature Range (DTR) class; 0=low, 1=medium; 2=high
                :cool_setpoint,           # [Double] Conditioned space cooling setpoint (F)
                :cool_design_grains,      # [Double] Difference between absolute humidity of the outdoor and indoor air (grains)
                :cool_indoor_wetbulb,     # [Double] Conditioned space cooling wetbulb temperature (F)
                :cool_indoor_enthalpy,    # [Double] Conditioned space cooling enthalpy (Btu/lb)
                :cool_outdoor_wetbulb,    # [Double] Outdoor cooling wetbulb temperature (F)
                :cool_design_temps,       # [Hash] Map of HPXML location => cooling design temperature (F)
                :ctd,                     # [Double] Cooling Temperature Difference, difference between setpoint and outdoor design temperature (F)
                :heat_setpoint,           # [Double] Conditioned space heating setpoint (F)
                :heat_design_temps,       # [Hash] Map of HPXML location => heating design temperature (F)
                :htd,                     # [Double] Heating Temperature Difference, difference between setpoint and outdoor design temperature (F)
                :acf,                     # [Double] Altitude Correction Factor
                :indoor_air_density,      # [Double] Conditioned space air density (lb/ft3)
                :outside_air_density,     # [Double] Outdoor air density (lb/ft3)
                :p_atm,                   # [Double] Pressure of air (atm)
                :p_psi,                   # [Double] Pressure of air (psi)
                :ground_conductivity)     # [Double] Ground conductivity (Btu/hr-ft-F)
end

# Object with design loads (component-level and totals) for the building, zone, or space
class DesignLoadValues
  attr_accessor(:Cool_Sens,               # [Double] Total sensible cooling load (Btu/hr)
                :Cool_Lat,                # [Double] Total latent cooling load (Btu/hr)
                :Cool_Tot,                # [Double] Total (sensible + latent) cooling load (Btu/hr)
                :Cool_Ducts_Sens,         # [Double] Ducts sensible cooling load (Btu/hr)
                :Cool_Ducts_Lat,          # [Double] Ducts latent cooling load (Btu/hr)
                :Cool_Windows,            # [Double] Windows sensible cooling load (Btu/hr)
                :Cool_Skylights,          # [Double] Skylights sensible cooling load (Btu/hr)
                :Cool_Doors,              # [Double] Doors sensible cooling load (Btu/hr)
                :Cool_Walls,              # [Double] Walls sensible cooling load (Btu/hr)
                :Cool_Roofs,              # [Double] Roofs sensible cooling load (Btu/hr)
                :Cool_Floors,             # [Double] Floors sensible cooling load (Btu/hr)
                :Cool_Slabs,              # [Double] Slabs sensible cooling load (Btu/hr)
                :Cool_Ceilings,           # [Double] Ceilings sensible cooling load (Btu/hr)
                :Cool_Infil_Sens,         # [Double] Infiltration sensible cooling load (Btu/hr)
                :Cool_Infil_Lat,          # [Double] Infiltration latent cooling load (Btu/hr)
                :Cool_Vent_Sens,          # [Double] Ventilation sensible cooling load (Btu/hr)
                :Cool_Vent_Lat,           # [Double] Ventilation latent cooling load (Btu/hr)
                :Cool_IntGains_Sens,      # [Double] Internal gains sensible cooling load (Btu/hr)
                :Cool_IntGains_Lat,       # [Double] Internal gains latent cooling load (Btu/hr)
                :Cool_BlowerHeat,         # [Double] Central system blower fan heat cooling load (Btu/hr)
                :Cool_AEDExcursion,       # [Double] Adequate Exposure Diversity (AED) excursion cooling load (Btu/hr)
                :Heat_Tot,                # [Double] Total sensible heating load (Btu/hr)
                :Heat_Ducts,              # [Double] Ducts sensible heating load (Btu/hr)
                :Heat_Windows,            # [Double] Windows sensible heating load (Btu/hr)
                :Heat_Skylights,          # [Double] Skylights sensible heating load (Btu/hr)
                :Heat_Doors,              # [Double] Doors sensible heating load (Btu/hr)
                :Heat_Walls,              # [Double] Walls sensible heating load (Btu/hr)
                :Heat_Roofs,              # [Double] Roofs sensible heating load (Btu/hr)
                :Heat_Floors,             # [Double] Floors sensible heating load (Btu/hr)
                :Heat_Slabs,              # [Double] Slabs sensible heating load (Btu/hr)
                :Heat_Ceilings,           # [Double] Ceilings sensible heating load (Btu/hr)
                :Heat_Infil,              # [Double] Infiltration sensible heating load (Btu/hr)
                :Heat_Vent,               # [Double] Ventilation sensible heating load (Btu/hr)
                :Heat_Piping,             # [Double] Hydronic piping sensible heating load (Btu/hr)
                :HourlyFenestrationLoads) # [Array<Double>] Array of hourly fenestration loads for AED curve (Btu/hr)

  def initialize
    @Cool_Sens = 0.0
    @Cool_Lat = 0.0
    @Cool_Tot = 0.0
    @Heat_Tot = 0.0
    @Heat_Ducts = 0.0
    @Cool_Ducts_Sens = 0.0
    @Cool_Ducts_Lat = 0.0
    @Cool_Windows = 0.0
    @Cool_Skylights = 0.0
    @Cool_AEDExcursion = 0.0
    @Cool_Doors = 0.0
    @Cool_Walls = 0.0
    @Cool_Roofs = 0.0
    @Cool_Floors = 0.0
    @Cool_Slabs = 0.0
    @Cool_Ceilings = 0.0
    @Cool_Infil_Sens = 0.0
    @Cool_Infil_Lat = 0.0
    @Cool_Vent_Sens = 0.0
    @Cool_Vent_Lat = 0.0
    @Cool_IntGains_Sens = 0.0
    @Cool_IntGains_Lat = 0.0
    @Cool_BlowerHeat = 0.0
    @Heat_Windows = 0.0
    @Heat_Skylights = 0.0
    @Heat_Doors = 0.0
    @Heat_Walls = 0.0
    @Heat_Roofs = 0.0
    @Heat_Floors = 0.0
    @Heat_Slabs = 0.0
    @Heat_Ceilings = 0.0
    @Heat_Infil = 0.0
    @Heat_Vent = 0.0
    @Heat_Piping = 0.0
    @HourlyFenestrationLoads = [0.0] * 12
  end
end

# Object with sizing values (loads, capacities, airflows, etc.) for a specific HVAC system
class HVACSizingValues
  attr_accessor(:Cool_Load_Sens,      # [Double] Total sensible cooling load (Btu/hr)
                :Cool_Load_Lat,       # [Double] Total latent cooling load (Btu/hr)
                :Cool_Load_Tot,       # [Double] Total (sensible + latent) cooling load (Btu/hr)
                :Heat_Load,           # [Double] Total heating sensible load (Btu/hr)
                :Heat_Load_Supp,      # [Double] Total heating sensible load for the HP backup (Btu/hr)
                :Cool_Capacity,       # [Double] Nominal total cooling capacity (Btu/hr)
                :Cool_Capacity_Sens,  # [Double] Nominal sensible cooling capacity (Btu/hr)
                :Heat_Capacity,       # [Double] Nominal heating capacity (Btu/hr)
                :Heat_Capacity_Supp,  # [Double] Nominal heating capacity for the HP backup (Btu/hr)
                :Cool_Airflow,        # [Double] Cooling airflow rate (cfm)
                :Heat_Airflow,        # [Double] Heating airflow rate (cfm)
                :GSHP_Loop_Flow,      # [Double] Ground-source heat pump water flow rate through the geothermal loop (gal/min)
                :GSHP_Bore_Holes,     # [Integer] Ground-source heat pump number of boreholes (#)
                :GSHP_Bore_Depth,     # [Double] Ground-source heat pump depth of each borehole (ft)
                :GSHP_G_Functions,    # [Array<Array<Double>, Array<Double>>] Ground-source heat pump G-functions
                :GSHP_Bore_Config)    # [String] Ground-source heat pump borefield configuration (HPXML::GeothermalLoopBorefieldConfigurationXXX)
end

# Object with data needed to write out the detailed output (used for populating an ACCA J1 form).
class DetailedOutputValues
  attr_accessor(:Area,           # [Double] Surface area (ft2)
                :Length,         # [Double] Slab length (ft)
                :Heat_HTM,       # [Double] Heating Heat Transfer Multiplier (HTM) (Btu/hr-ft2)
                :Cool_HTM,       # [Double] Cooling Heat Transfer Multiplier (HTM) (Btu/hr-ft2)
                :Heat_Load,      # [Double] Total sensible heating load (Btu/hr)
                :Cool_Load_Sens, # [Double] Total sensible cooling load (Btu/hr)
                :Cool_Load_Lat)  # [Double] Total latent cooling load (Btu/hr)

  def initialize(heat_load:, cool_load_sens:, cool_load_lat:, area: nil, length: nil, heat_htm: nil, cool_htm: nil)
    @Heat_Load = heat_load.round
    @Cool_Load_Sens = cool_load_sens.round
    @Cool_Load_Lat = cool_load_lat.round
    @Area = area.round(2) unless area.nil?
    @Length = length.round unless length.nil?
    @Heat_HTM = heat_htm.round(2) unless heat_htm.nil?
    @Cool_HTM = cool_htm.round(2) unless cool_htm.nil?
  end
end
