class RbrController < ApplicationController
  include ActionView::Helpers::UrlHelper
  include Rails.application.routes.url_helpers

  # TODO- make the 83_d_tarmac.lsp / filename show at the top as you scroll down, so you always know which is which

  TOLERANCE = 0.0001
  def index
  end

  def compare
    begin
      sanity_check
      @warnings = []
      setups = normalize_sections(process_all_setups)
      differences = find_differences(setups)
      render :compare, locals: { setups: setups, differences: differences }
    rescue StandardError => e
      flash[:error] = e.message
      redirect_to root_path
    end
  end

  private

  def sanity_check
    raise 'Please add setup files to submit' unless params['files']
    raise 'Please submit at least two files' unless params['files']&.count > 1

    params['files'].each do |file|
      unless file.original_filename.end_with?('.lsp')
        raise 'Please submit only RBR LSP Setup files (files with a .lsp extension)'
      end
      unless file.size / 1000 < 10_000
        raise 'Please submit LSP files (text only) that are smaller than 10 MB'
      end
    end
  end

  def process_all_setups
    params['files'].map{ |setup_file| process_setup(setup_file) }
  end

  def process_setup(setup_file)
    setup_data = { filename: setup_file.original_filename }
    @rows = setup_file.open().readlines.map(&:strip).reject(&:empty?)
    @index = 0
    section = nil

    while @index < @rows.count
      case @rows[@index]
      when /\(\(".+"/, '))'
      when /(\w+)\s+\(".+"$/
        section = $~[1]
        setup_data[section] = parse_section(section)
      when /^(\w+)$/
        section = $~[1]
      when /^\(.*".+"$/
        setup_data[section] = parse_section(section)
      else
        @warnings.push("#{setup_data[:filename]}: unknown line encountered on row #{@index}. #{@rows[@index]}")
      end

      @index += 1
    end

    setup_data
  end

  def parse_section(section)
    data = {}
    while @index < @rows.count
      @index += 1
      row = @rows[@index]
      return data if row == ')'

      match = row.match(/(\w+)(?:\s+(.*))?/)
      raise "Unexpected regex match in parse_section at row number #{@index}: #{row}: #{match}" unless match

      key = match[1]
      if data[key]
        next if match[2].nil?

        raise "#{section}: #{key} is trying to override an existing value of #{data}" if data[key].present?
      end

      numeric_val = match[2]
      if partial_match = numeric_val.match(/(\d*\.?\d+)\s+([a-zA-Z]+\w+)\s+(\d*\.?\d+)/)
        # Fix formatting concerns- CenterSpeedMapVelocity in E30 file for example (and others).
        # Mostly these files are newline delimited but this is an example of multiple values appearing on the same line
        numeric_val = partial_match[1]
        @rows.insert(@index + 1, "#{partial_match[2]} #{partial_match[3]}")
      end

      data[key] = format_value(numeric_val, key)
    end

    data
  end

  def format_value(value, key)
    if match = value.match(/([+-]?\d+(?:\.\d+)?)\s+([+-]?\d+(?:\.\d+)?)\s+([+-]?\d+(?:\.\d+)?)/)
      "#{clean_number(match[1])} #{clean_number(match[2])} #{clean_number(match[3])}"
    elsif key =~ /Length|Height/
      "#{clean_number(value, modifier: 1000)} mm"
    elsif key.include? 'Stiffness'
      "#{clean_number(value, modifier: 1.0/1000)} kN/m"
    elsif key.include? 'Damping'
      "#{clean_number(value, modifier: 1.0/1000)} kN/m/s"
    elsif key.include? 'Pressure'
      "#{clean_number(value, modifier: 1.0/1000)} kPa"
    elsif key.include? 'Torque'
      "#{clean_number(value, modifier: 1)} Nm"
    elsif key == 'BumpHighSpeedBreak'
      "#{clean_number(value, modifier: 1)} m/s"
    else
      "#{clean_number(value)}"
    end
  end

  def clean_number(value, modifier: 1)
    value = (value.to_f * modifier).round(4)
    (value % 1 == 0) ? value.to_i : value
  end

  def normalize_sections(setups)
    setups.each do |setup|
      setup.each do |section_name, values|
        next if section_name == :filename

        values.keys.each do |key|
          setups.each do |set|
            set[section_name][key] = 'N/A' unless set[section_name][key]
          end
        end
      end
    end

    setups.each do |setup|
      remove_clutter(setup)

      setup.transform_values! do |section|
        section.is_a?(Hash) ? section.sort.to_h : section
      end

      filename = setup.delete(:filename)
      sorted_setup = setup.sort.to_h
      sorted_setup[:filename] = filename if filename
      setup.clear
      setup.merge!(sorted_setup)
    end
  end

  def remove_clutter(setup)
    setup['SpringDamperBack'] = setup.delete('SpringDamperLB')
    setup.delete('SpringDamperRB')
    setup['SpringDamperFront'] = setup.delete('SpringDamperLF')
    setup.delete('SpringDamperRF')

    setup['TyreBack'] = setup.delete('TyreLB')
    setup.delete('TyreRB')
    setup['TyreFront'] = setup.delete('TyreLF')
    setup.delete('TyreRF')

    setup['WheelBack'] = setup.delete('WheelLB')
    setup.delete('WheelRB')
    setup['WheelFront'] = setup.delete('WheelLF')
    setup.delete('WheelRF')

    setup.delete('Engine') if setup['Engine'].size == 1 && setup['Engine'].first.first == 'Features_NGP'
  end

  def find_differences(setups)
    differences = {}
    setups.each do |setup|
      setup.each do |section_name, vals|
        next if section_name == :filename

        vals.each do |key, val|
          vals_key = section_name + key
          if differences[vals_key]
            differences[vals_key].push(val)
          else
            differences[vals_key] = [val]
          end
        end
      end
    end

    differences.each do |key, vals|
      differences[key] = vals.uniq.length != 1

      if vals.all? { |v| v.to_s.match?(/\A[-+]?\d*\.?\d+(e[-+]?\d+)?\z/i) }
        numbers = vals.map(&:to_f)
        min, max = numbers.minmax
        # Floats can differ a tiny bit, and still be considered *not different* for our purposes
        differences[key] = (max - min) > TOLERANCE
      else
        # Non-numeric values still have to match exactly
        differences[key] = vals.uniq.length != 1
      end
    end
    differences
  end

end