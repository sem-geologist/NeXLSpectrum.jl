using Polynomials
using DataFrames
using PeriodicTable

# Keeps track of the number of spectra in this session.

let spectrumIndex = 1
    global spectrumCounter() = (spectrumIndex += 1)
end;

"""
    Spectrum
A structure to hold spectrum data (energy scale, counts and metadata).
Metadata is identified by a symbol. Predefined symbols include
    :BeamEnergy    # In eV
    :Elevation     # In degrees
    :LiveTime      # In seconds
    :RealTime      # In seconds
    :ProbeCurrent  # In nano-amps
    :Name          # A string
    :Owner         # A string
    :StagePosition # A Dict with entries :X, :Y, :Z, :R, :TX in millimeters and degrees
    :Comment       # A string
    :Composition   # A Material
	:Elements      # A collection of elements in the material
    :Detector      # A Detector like a SimpleEDS
    :Filename      # Source filename
    :Coating       # A Film (eg. 10 nm of C|Au etc.)

Not all spectra will define all properties.
If spec is a Spectrum then
    spec[123] # will return the number of counts in channel 123
    spec[134.] # will return the number of counts in the channel at energy 134.0 eV
    spec[:Comment] # will return the property comment
"""
struct Spectrum
    energy::EnergyScale
    counts::Array{<:Real}
    properties::Dict{Symbol,Any}
    function Spectrum(energy::EnergyScale, data::Array{<:Real},props::Dict{Symbol,Any})
        props[:Name] = get(props, :Name, "Spectrum[$(spectrumCounter())]")
        return new(energy, data, props)
    end
end

channelcount(spec::Spectrum) = length(spec.counts)

function Base.show(io::IO, spec::Spectrum)
    print(io, "Spectrum[")
    print(io, "name = ",get(spec, :Name, "None"),", ")
    println(io, "owner = ",get(spec, :Owner, "Unknown"))
    cols, rows = 80, 16
    # how much to plot
    e0_eV = haskey(spec,:BeamEnergy) ?
        e0_eV=spec.properties[:BeamEnergy] :
        energy(length(spec), spec)
    maxCh = min(channel(e0_eV, spec),length(spec))
    step = maxCh ÷ cols
    max = maximum(spec.counts)
    maxes = fill(0.0,cols)
    for i in 1:cols
        maxes[i] = rows*(maximum(spec.counts[(i-1)*step+1:i*step])/max)
    end
    for r in 1:rows
        ss=""
        for i in 1:cols
            ss = ss * (r ≥ rows - maxes[i] ? "*" : " ")
        end
        if r==1
            println(io, ss, " ", max)
        elseif r==rows
            println(io, ss," ",0.001*get(spec,:BeamEnergy,-1.0)," keV]")
        else
            println(io, ss)
        end
    end
end

"""
    tabulate(spec::Spectrum)

Converts the spectrum energy and counts data into a table.
"""
tabulate(spec::Spectrum)::DataFrame =
    DataFrame(E=energyscale(spec),I=counts(spec))

function split_emsa_header_item(line::AbstractString)
    p = findfirst(":",line)
    if p ≠ nothing
        tmp = uppercase(strip(SubString(line,2:p.start-1)))
        pp = findfirst("-",tmp)
        if pp ≠ nothing
            key, mod = strip(SubString(tmp,0::pp.start-1)), strip(SubString(tmp,pp.start+1))
        else
            key, mod = tmp, nothing
        end
        value = strip(SubString(line,p.stop+1))
        # println(key," = ",value)
        return (key, value, mod)
    else
        return nothing
    end
end

function parsed2stdcmp(value::AbstractString)::Material
	try
		sp=split(value,",")
		name=sp[1]
		mf = Dict{Element,Float64}()
		den = missing
		for item in sp[2:end]
			if item[1]=='(' && item[end]==')'
				sp2=split(item[2:end-1],":")
				mf[element(sp2[1])]=parse(Float64,sp2[2])
			else
				den = parse(Float64,item)
			end
		end
		return material(name, mf, den)
	catch err
		warn("Error parsing composition $(value) - $(err)")
	end
end

function parsecoating(value::AbstractString)::Union{Film,Missing}
    i=findfirst(value," nm of ")
	if !ismissing(i)
		try
			thk = parse(Float64,value[1:i])*1.0e-7 // cm
			mat = parse2stdcmp(Material, value[i+7:end])
			return Film(mat,thickness)
		catch err
			warn("Error parsing $(value) as a coating $(value)")
		end
	end
    return missing
end

function readEMSA(filename::AbstractString, det::Detector)::Union{Spectrum,Nothing}
	spec = readEMSA(fieldname)
	if !isnothing(spec)
		if abs(channel(energy(1,det))-1)>1
			error("Spectrum and detector calibrations don't match - Offset.")
		end
		test = det.channelcount/2
		if abs(channel(energy(test,det))-test)>1
			error("Spectrum and detector calibrations don't match - Gain.")
		end
		spec[:Detector] = det
	end
	return spec
end

"""
	matching(spec::Spectrum, res::Resolution, lld::Int=1)::SimpleEDS

Build an EDSDetector to match the channel count and energy scale in this spectrum.
"""
matching(spec::Spectrum, res::Resolution, lld::Int=1)::SimpleEDS =
	SimpleEDS(channelcount(spec), spec.energy, res, lld)

"""
	matching(spec::Spectrum, resMnKa::Float64, lld::Int=1)::SimpleEDS

Build an EDSDetector to match the channel count and energy scale in this spectrum.
"""
matching(spec::Spectrum, resMnKa::Float64, lld::Int=1)::SimpleEDS =
	SimpleEDS(channelcount(spec), spec.energy, MnKaResolution(resMnKa), lld)

"""
    readEMSA(filename::AbstractString)::Union{Spectrum,Nothing}

Read an ISO/EMSA format spectrum from a disk file at the specified path.
"""
function readEMSA(filename::AbstractString)::Union{Spectrum,Nothing}
    open(filename,"r") do f
        energy, counts = LinearEnergyScale(0.0,10.0), Int[]
        props = Dict{Symbol,Any}()
        props[:Filename]=filename
        inData, lx = 0, 0
        stgpos = Dict{Symbol,Float64}()
        for line in eachline(f)
            lx+=1
            if (lx ≤ 2)
                res = split_emsa_header_item(line)
                if (res==nothing) || ((lx==1) && (res[1]!="FORMAT" || uppercase(res[2])!="EMSA/MAS SPECTRAL DATA FILE"))
                    return nothing
                end
                if (res==nothing) || ((lx==2) && (res[1]!="VERSION" || res[2]!="1.0"))
                    return nothing
                end
            elseif inData>0
                if startswith(line, "#ENDOFDATA")
                    break
                else
                    for cc in split(line, ",")
                        num = match(r"[-+]?[0-9]*\.?[0-9]+", cc)
                        if num ≠ nothing
                            append!(counts, round(Int, parse(Float64, num.match), RoundNearestTiesAway))
                        end
                        inData=inData+1
                    end
                end
            elseif startswith(line,"#")
                res = split_emsa_header_item(line)
                if res ≠ nothing
                    key, value = res
                    if key == "SPECTRUM"
                        inData = 1
                    elseif key == "BEAMKV"
                        props[:BeamEnergy]=1000.0*parse(Float64,value) # in eV
                    elseif key == "XPERCHAN"
                        energy = LinearEnergyScale(energy.offset, parse(Float64,value))
                    elseif key == "LIVETIME"
                        props[:LiveTime]=parse(Float64,value)
                    elseif key == "REALTIME"
                        props[:RealTime]=parse(Float64,value)
                    elseif key == "PROBECUR"
                        props[:ProbeCurrent]=parse(Float64,value)
                    elseif key == "OFFSET"
                        energy = LinearEnergyScale(parse(Float64,value), energy.width)
                    elseif key == "TITLE"
                        props[:Name]=value
                    elseif key == "OWNER"
                        props[:Owner]=value
                    elseif key == "ELEVANGLE"
                        props[:Elevation] = parse(Float64, value)
                    elseif key == "XPOSITION"
                        stgpos[:X] = parse(Float64, value)
                    elseif key == "YPOSITION"
                        stgpos[:Y] = parse(Float64, value)
                    elseif key == "ZPOSITION"
                        stgpos[:Z] = parse(Float64, value)
                    elseif key == "COMMENT"
                        prev = getindex(props,:Comment,missing)
                        props[:Comment] = prev ≠ missing ? prev*"\n"*value : value
                    elseif key== "#D2STDCMP"
                        props[:Composition] = parsed2stdcmp(value)
                    elseif key== "#CONDCOATING"
                        props[:Coating] = parsecoating(value)
                    end
                end
            end
        end
        if startswith( props[:Name], "Bruker Nano")
            if haskey(props, :Composition)
                props[:Name]=name(props[:Composition])
            else
                props[:Name]=basename(filename[1:end-4])
            end
        end
        props[:StagePosition] = stgpos
        return Spectrum(energy, counts, props)
    end
end

setproperty!(spec::Spectrum, sym::Symbol, val::Any) = setindex!(props, sym, val)

Base.get(spec::Spectrum, sym::Symbol, def::Any=missing) = get(spec.properties, sym, def)

Base.getindex(spec::Spectrum, sym::Symbol)::Any = spec.properties[sym]

Base.getindex(spec::Spectrum, idx::Int) = spec.counts[idx]

Base.get(spec::Spectrum, idx::Int, def=convert(typeof(spec.counts[1]), 0)) = get(spec.counts, idx, def)

Base.setindex!(spec::Spectrum, val::Any, sym::Symbol) =
    spec.properties[sym] = val

Base.setindex!(spec::Spectrum, val::Real, idx::Int) =
    spec.counts[idx] = convert(typeof(spec.counts[1]), val)

Base.haskey(spec::Spectrum, sym::Symbol) = haskey(spec.properties,sym)

"""
    elements(spec::Spectrum, withcoating = false, def=missing)

Returns a list of the elements associated with this spectrum. <code>withcoating</code> determines whether the coating
elements are also added.
"""
function elements(spec::Spectrum, withcoating=false, def=missing)
	res = haskey(spec, :Elements) ? spec[:Elements] :
		(haskey(spec, :Composition) ? collect(keys(spec[:Composition])) : [])
	append!(res, withcoating && haskey(spec, :Coating) ? keys(material(spec[:Coating])) : [])
	return length(res) == 0 ? def : res
end

"""
    dose(spec::Spectrum, def=missing)

The probe dose in nano-amp seconds
"""
function dose(spec::Spectrum, def=missing)::Union{Float64,Missing}
    res = get(spec.properties,:LiveTime, missing)*get(spec,:ProbeCurrent, missing)
    return isequal(res,missing) ? def : res
end

"""
    length(spec::Spectrum)

The length of a spectrum is the number of channels.
"""
Base.length(spec::Spectrum) = length(spec.counts)

Base.eachindex(spec::Spectrum) = 1:length(spec.counts)

"""
    NeXLCore.energy(ch::Int, spec::Spectrum)

The energy of the start of the ch-th channel.
"""
NeXLCore.energy(ch::Int, spec::Spectrum)::Float64 = energy(ch, spec.energy)

"""
    width(ch::Int, spec::Spectrum)::Float64

Returns the width of the <code>ch</code> channel
"""
width(ch::Int,spec::Spectrum) = energy(ch+1,spec) - energy(ch,spec)

"""
    channel(eV::Float64, spec::Spectrum)

The index of the channel containing the specified energy.
"""
channel(eV::Float64, spec::Spectrum)::Int = channel(eV, spec.energy)

"""
    counts(spec::Spectrum, numType::Type{T})::Vector{T} where {T<:Number}

Creates a copy of the spectrum counts data as the specified Number type.
"""
counts(spec::Spectrum, numType::Type{T}=Float64) where {T<:Number} = map(n->convert(numType,n), spec.counts)

"""
    counts(spec::Spectrum, channels::UnitRange{Int}, numType::Type{T})::Vector{T} where {T<:Number}

Creates a copy of the spectrum counts data as the specified Number type.
"""
counts(spec::Spectrum, channels::UnitRange{Int}, numType::Type{T}) where {T<:Real} =
    map(n->convert(numType,n), spec.counts[channels])


"""
    normalizeDoseWidth(spec::Spectrum)::Vector{Float64}

Normalize the channel intensities to counts/(nA⋅s⋅eV).  Good for comparing spectra collected at different detector
channel widths.
"""
function normalizeDoseWidth(spec::Spectrum, defDose=missing)::Vector{Float64}
	ds=dose(spec, defDose)
	if ismissing(ds)
		error("The required spectrum dose in not available in normalizeDoseWidth(spec).")
	end
	return map(ch->convert(Float64,spec.counts[ch])/(ds*width(ch,spec)), eachindex(spec.counts))
end

"""
	findmax(spec::Spectrum, chs::UnitRange{Int})

Returns the (maximum intensity, channel index) over the specified range of channels
"""
function Base.findmax(spec::Spectrum, chs::UnitRange{Int})
	max=findmax(spec.counts[chs])
	return (max[1]+chs.start-1, max[2])
end

"""
	findmax(spec::Spectrum)

Returns the (maximum intensity, channel index) over all channels
"""
Base.findmax(spec::Spectrum) = findmax(spec.counts)

"""
   integrate(spec, channels)

Sums all the counts in the specified channels.  No background correction.
"""
integrate(spec::Spectrum, channels::UnitRange{Int}) = sum(spec.counts[channels])

"""
   integrate(spec, channels)

Sums all the counts in the specified energy range.  No background correction.
"""
integrate(spec::Spectrum, energyRange::StepRangeLen{Float64}) =
    sum(spec.counts[channel(energyRange[1],spec):channel(energyRange[end],spec)])

"""
    integrate(spec::Spectrum, back1::UnitRange{Int}, peak::UnitRange{Int}, back2::UnitRange{Int})::Float64
Perform a background corrected peak integration using channel ranges. Fits a line to each background region and
extrapolates the background from the closest background channel through the peak region.
"""
function integrate(spec::Spectrum, back1::UnitRange{Int}, peak::UnitRange{Int}, back2::UnitRange{Int})::Float64
    p1=polyfit(back1, spec.counts[back1], 1)
    p2=polyfit(back2, spec.counts[back2], 1)
    c1, c2 = back1.stop, back2.start
    i1, i2 = p1(c1), p2(c2)
    m = (i2-i1)/(c2-c1)
    back = Poly([i1-m*c1, m])
    sum(spec.counts[peak]-map(back,peak))
end

"""
    integrate(spec::Spectrum, back1::StepRangeLen{Float64}, peak::StepRangeLen{Float64}, back2::StepRangeLen{Float64})::Float64
Perform a background corrected peak integration using energy (eV) ranges. Converts the energy ranges to channels
ranges before performing the integral.
"""
function integrate(spec::Spectrum, back1::StepRangeLen{Float64}, peak::StepRangeLen{Float64}, back2::StepRangeLen{Float64})::Float64
    b1i = channel(back1[back1.offset],spec):channel(back1[end],spec)
    b2i = channel(back2[back2.offset],spec):channel(back2[end],spec)
    pi = channel(peak[peak.offset],spec):channel(peak[end],spec)
    integrate(spec, b1i, pi, b2i)
end

"""
    integrate(spec::Spectrum)

Total integral of all counts from the LLD to the beam energy
"""
function integrate(spec::Spectrum)
	det = get(spec, :Detector, missing)
	last = channel(get(spec, :BeamEnergy, energy(length(spec.counts),spec)),spec)
	first = !ismissing(det) ? lld(det) : 1
	return integrate(spec,first:last)
end

"""
    energyscale(spec::Spectrum)

Returns an array with the bin-by-bin energies
"""
energyscale(spec::Spectrum) =
    energyscale(spec.energy, 1:length(spec))

"""
    basicEDS(spec::Spectrum, fwhmatmnka::Float64)

Build a SimpleEDS object for this spectrum with the specified FWHM at Mn Kα.
"""
basicEDS(spec::Spectrum, fwhmatmnka::Float64) =
    SimpleEDS(length(spec),spec.energy,MnKaResolution(fwhmatmnka))


"""
    subsample(spec::Spectrum, frac::Float64)

Subsample the counts data in a spectrum according to a statistically valid algorithm.  Returns
<code>spec</code> if frac>=1.0.
"""
function subsample(spec::Spectrum, frac::Float64)::Spectrum
	@assert frac>0.0 "frac must be larger than zero."
	@assert frac<=1.0 "frac must be less than or equal to 1.0."
    ss(n, f) = n > 0 ? mapreduce(i -> rand() < f ? 1 : 0, + , 1:n) : 0
    frac = max(0.0, min(frac, 1.0))
	if frac<1.0
	    props = deepcopy(spec.properties)
	    props[:LiveTime]=frac*get(spec, :LiveTime, 1.0)
	    props[:RealTime]=frac*get(spec, :RealTime, 1.0)
	    return Spectrum(spec.energy, map(n -> ss(floor(Int,n), frac), spec.counts), props)
	else
		return spec
	end
end


"""
    estimateBackground(data::AbstractArray{Float64}, channel::Int, width::Int=5, order::Int=2)

Returns the tangent to the a quadratic fit to the counts data centered at channel with width
"""
function estimateBackground(data::AbstractArray{Float64}, channel::Int, width::Int = 5, order::Int = 2)::Poly
    fit = polyfit(-width:width, data[max(1, channel - width):min(length(data), channel + width)], order)
    return Poly([fit(0), polyder(fit)(0)])
end

"""
    modelBackground(spec::Spectrum, chs::UnitRange{Int}, ash::AtomicShell)

spec: A spectrum containing a peak centered on chs
chs:  A range of channels containing a peak
ash:  The edge (as an AtomicShell)

A simple model for modeling the background under a characteristic x-ray peak. The model
fits a line to low and high energy background regions around chs.start and chs.end. If
the low energy line extended out to the edge energy is larger than the high energy line
at the same energy, then a negative going edge is fit between the two. Otherwise a line
is fit between the low energy side and the high energy side. This model only works when
there are no peak interference over the range chs.
"""
function modelBackground(spec::Spectrum, chs::UnitRange{Int}, ash::AtomicShell)
    bl=estimateBackground(counts(spec),chs.start,5)
    bh=estimateBackground(counts(spec),chs.stop,5)
    ec = channel(energy(ash),spec)
    if (ec<chs.stop) && (bl(ec-chs.start)>bh(ec-chs.stop)) && (energy(ash) < 2.0e3)
        res=zeros(Float64,length(chs))
        for y in chs.start:ec-1
            res[y-chs.start+1]=bl(y-chs.start)
        end
        res[ec-chs.start+1]=0.5*(bl(ec-chs.start)+bh(ec-chs.stop))
        for y in ec+1:chs.stop
            res[y-chs.start+1]=bh(y-chs.stop)
        end
    else
        s=(bh(0)-bl(0))/length(chs)
        back = Poly([bl(0), s])
        res=back.(collect(0:length(chs)-1))
    end
    return res
end


"""
    modelBackground(spec::Spectrum, chs::UnitRange{Int})

spec: A spectrum containing a peak centered on chs
chs:  A range of channels containing a peak

A simple model for modeling the background under a characteristic x-ray peak. The model
fits a line between the  low and high energy background regions around chs.start and chs.end.
This model only works when there are no peak interference over the range chs.
"""
function modelBackground(spec::Spectrum, chs::UnitRange{Int})
    bl=estimateBackground(counts(spec),chs.start,5)
    bh=estimateBackground(counts(spec),chs.stop,5)
    s=(bh(0)-bl(0))/length(chs)
    back = Poly([bl(0), s])
    return back.(collect(0:length(chs)-1))
end

"""
    extractcharacteristic(spec::Spectrum, lowBack::UnitRange{Int}, highBack::UnitRange{Int})::Vector{Float64}

Extract the characteristic intensity for the peak located within chs with an edge at ash.
"""
function extractcharacteristic(spec::Spectrum, chs::UnitRange{Int}, ash::AtomicShell)::Vector{Float64}
    return counts(spec,chs,Float64)-modelBackground(spec,chs,ash)
end


"""
    peak(spec::Spectrum, chs::UnitRange{Int}, ash::AtomicShell)::Float64

Estimates the peak intensity for the characteristic X-ray in the specified range of channels.
"""
peak(spec::Spectrum, chs::UnitRange{Int})::Float64 =
    return sum(counts(spec,chs,Float64))- back(spec,chs)

"""
    back(spec::Spectrum, chs::UnitRange{Int}, ash::AtomicShell)::Float64

Estimates the background intensity for the characteristic X-ray in the specified range of channels.
"""
back(spec::Spectrum, chs::UnitRange{Int})::Float64 = sum(modelBackground(spec,chs))


"""
    peaktobackground(spec::Spectrum, chs::UnitRange{Int}, ash::AtomicShell)::Float64

Estimates the peak-to-background ratio for the characteristic X-ray intensity in the specified range of channels
which encompass the specified AtomicShell.
"""
function peaktobackground(spec::Spectrum, chs::UnitRange{Int}, ash::AtomicShell)::Float64
    back = sum(modelBackground(spec,chs,ash))
    return (sum(counts(spec,chs,Float64))-back)/back
end

"""
    estkratio(unk::Spectrum, std::Spectrum, chs::UnitRange{Int})

Estimates the k-ratio from niave models of peak and background intensity.  Only works if the peak is not interfered.
"""
estkratio(unk::Spectrum, std::Spectrum, chs::UnitRange{Int}) =
    peak(unk, chs)*dose(std)/(peak(std, chs)*dose(unk))

"""
    describe(io, spec::Spectrum)

Outputs a description of the data in the spectrum.
"""
function details(io::IO, spec::Spectrum)
	println(io, "           Name:   $(spec[:Name])")
	println(io, "    Beam energy:   $(get(spec, :BeamEnergy, missing)/1000.0) keV")
	println(io, "  Probe current:   $(get(spec, :ProbeCurrent, missing)) nA")
	println(io, "      Live time:   $(get(spec, :LiveTime, missing)) s")
	println(io, "        Coating:   $(get(spec,:Coating, "None"))")
	println(io, "       Detector:   $(get(spec, :Detector, missing))")
	println(io, "        Comment:   $(get(spec, :Comment, missing))")
	println(io, "       Integral:   $(integrate(spec)) counts")
	comp = get(spec, :Composition, missing)
	if !ismissing(comp)
		println(io, "    Composition:   $(comp)")
		det = get(spec, :Detector, missing)
		if !ismissing(det)
			coating = get(spec, :Coating, missing)
			comp2 = collect(keys(comp))
			if !ismissing(coating)
				append!(comp2, keys(coating.material))
			end
			for elm1 in keys(comp)
				for ext1 in extents(elm1, det, 1.0e-4)
					print(io, "            ROI:   $(elm1.symbol)[$(ext1)]")
					printi=true
					for elm2 in comp2
						if elm2 ≠ elm1
							for ext2 in extents(elm2, det, 1.0e-4)
								if length(intersect(ext1,ext2))>0
									print(io, "\n              Warning: $(elm1.symbol)[$(ext1)] intersects with $(elm2.symbol)[$(ext2)]")
									printi=false
								end
							end
						end
					end
					p, b = peak(spec, ext1), back(spec,ext1)
					σ = p/sqrt(b)
					println(io, printi ? " = $(round(Int,p)) counts over $(round(Int,b)) counts - σ = $(round(Int,σ))" : "")
				end
			end
		end
	end
	return nothing
end

"""
    details(spec::Spectrum)

Outputs a description of the data in the spectrum to standard output.
"""
details(spec::Spectrum) = details(stdout, spec)
