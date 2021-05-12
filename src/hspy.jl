using HDF5: attributes, h5open, ishdf5

function read_hspy(filename::String, name=nothing, inst=nothing)
    function read_attributes(fid)
        cs = attributes(fid)
        Dict(map(k->k=>read(cs,k),keys(cs))...)
    end
    function assign(props, prop, val) 
        if !ismissing(val) props[prop]=val end
    end 
    h5open(filename,"r") do hdf5
        ff = read_attributes(hdf5)
        @assert get(ff, "file_format", "") == "HyperSpy" "This file does not appear to be a HyperSpy file."
        ver = parse(Float64, get(ff, "file_format_version", 0.0))
        (ver < 1.2) && @warn "This reader may not be compatible with version $ver of HyperSpy data files."
        props = Dict{Symbol,Any}()
        props[:Filename] = filename
        if haskey(hdf5, "Experiments")
            exps = keys(hdf5["Experiments"])
            exp = something(name, first(exps))
            exp_key = "Experiments/$exp" 
            sig_key = "$exp_key/metadata/Signal"
            if haskey(hdf5, sig_key)
                sig = read_attributes(hdf5[sig_key])
                st = get(sig, "signal_type", "Unknown")
                if st == "EDS_TEM"
                    props[:SignalType] = "EDS-TEM"
                elseif st == "EDS_SEM"
                    props[:SignalType] = "EDS-SEM"
                elseif st == "EELS"
                    props[:SignalType] = "STEM-EELS"
                else
                    @warn "Unsupported signal type $st which loading a HyperSpy file."
                    assign(props, :SignalType, st)
                end
                @assert get(sig, "recorded_by", "spectrum") == "spectrum" "Orderings other than `spectrum` are not supported"
            end            
            aqin_key = "$exp_key/metadata/Acquisition_instrument"
            if haskey(hdf5, aqin_key)
                insts = keys(hdf5[aqin_key])
                inst = something(inst, first(insts))
                assign(props, :InstrumentType, inst)
                inst_key = "$aqin_key/$inst"
                if haskey(hdf5, inst_key)
                    inst_attr=read_attributes(hdf5[inst_key])
                    assign(props, :ProbeCurrent, get(inst_attr, "beam_current", missing)) # nA
                    assign(props, :BeamEnergy, get(inst_attr, "beam_energy", missing)*1000.0) # keV
                    assign(props, :Instrument,  get(inst_attr, "microscope", missing))
                    assign(props, :WorkingDistance, get(inst_attr,"working_distance", missing)*0.1) # mm
                    if haskey(hdf5[inst_key],"Stage")
                        stage_attr = read_attributes(hdf5["$inst_key/Stage"])
                        props[:Stage] = Dict(
                            :X => get(stage_attr, "x", 0.0)*0.1,
                            :Y => get(stage_attr, "y", 0.0)*0.1,
                            :Z => get(stage_attr, "z", 0.0)*0.1,
                            :R => deg2rad(get(stage_attr, "rotation", 0.0)),
                            :T => deg2rad(get(stage_attr, "tilt_alpha", 0.0)),
                            :B => deg2rad(get(stage_attr, "tilt_beta", 0.0)),
                        )
                    end
                    det_key = "$inst_key/Detector"
                    if haskey(hdf5, det_key)
                        det_attr = read_attributes(hdf5[det_key])
                        assign(props, :DetectorType, get(det_attr,"detector_type",missing))
                        eds_key = "$det_key/EDS"
                        if haskey(hdf5, eds_key)
                            eds_attr = read_attributes(hdf5[eds_key])
                            assign(props, :Azimuthal, get(eds_attr, "azimuth_angle", missing)*deg2rad(1.0))
                            assign(props, :Elevation, get(eds_attr, "elevation_angle", missing)*deg2rad(1.0))
                            res = get(eds_attr, "energy_resolution_MnKa", missing)
                            assign(props, :LiveTime, get(eds_attr, "live_time", missing))
                            assign(props, :RealTime, get(eds_attr, "real_time", missing))
                            samp_attr = read_attributes(hdf5["$exp_key/metadata/Sample"])
                            assign(props, :Sample, get(samp_attr, "description", missing))
                            elms = get(samp_attr, "elements", missing)
                            if !ismissing(elms)
                                props[:Elements] = map(e->parse(Element, e), elms)
                            end
                        end
                    end
                end
            end
            gen_key = "$exp_key/metadata/General"
            if haskey(hdf5, gen_key)
                general = read_attributes(hdf5[gen_key])
                assign(props, :Owner, get(general, "authors", missing))
                datetime = get(general, "date", "1.1.1970")  * "T" * #
                    get(general, "time", "00:00:00") # * " " * get(general, "time_zone", "UTC")
                try
                    assign(props, :AcquisitionTime, DateTime(datetime, dateformat"dd.mm.yyyyTHH:MM:SS"))
                catch 
                    @warn "Error parsing timestamp: $datetime"
                end
                assign(props, :Description, get(general, "notes", missing))
                assign(props, :Name, get(general, "title", missing))
            end
            scale, offset = 10.0, 0.0
            axisnames, fov, offsets = String[], Float64[], Float64[]
            i=0
            while haskey(hdf5["$exp_key"],"axis-$i")
                axis = read_attributes(hdf5["$exp_key/axis-$i"])
                unitname = uppercase(get(axis, "units", "eV")) 
                if unitname == "KEV"
                    unit = 1000.0
                elseif unitname == "EV"
                    unit = 1.0
                elseif unitname == "MM"
                    unit = 0.1
                elseif unitname == "NM"
                    unit = 1.0e-7
                else
                    unit = 1.0
                end
                push!(axisnames, uppercase(get(axis, "name", "axis-$i")))
                scale = get(axis, "scale", 10.0/unit) * unit
                offset = get(axis, "offset", 0.0) * unit
                push!(fov, scale * get(axis, "size", 1))
                push!(offsets, offset)
                i+=1
            end
            data = read(hdf5, "$exp_key/data")
            axisnames = reverse(axisnames[1:end-1])
            fov = reverse(fov[1:end-1])
            offsets = reverse(offsets[1:end-1])
            # Now swap the first two axes because column major vs row major...
            if length(axisnames)>1
                newdims = collect(1:length(axisnames)+1)
                newdims[2], newdims[3] = newdims[3], newdims[2]
                data = permutedims(data, newdims)
                axisnames[1], axisnames[2] = axisnames[2], axisnames[1]
                fov[1], fov[2] = fov[2], fov[1]
                offsets[1], offsets[2] = offsets[2], offsets[1]  
            end
            if !ismissing(res)
                props[:Detector] = simpleEDS(size(data,1), scale, offset, res)
            end
            return HyperSpectrum(LinearEnergyScale(offset, scale), props, data, #
                axisnames=axisnames, fov=fov, offset=offsets)
        end
    end
end

function ishspy(filename::String)::Bool
    return ishdf5(filename) && h5open(filename,"r") do h
        a = attributes(h)
        haskey(a,"file_format") && read(a["file_format"])=="HyperSpy"
    end
end