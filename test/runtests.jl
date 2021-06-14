using Korg
using Test

include("continuum_opacity.jl")

@testset "atomic data" begin 
    @test (Set(Korg.atomic_symbols) == Set(keys(Korg.atomic_masses))
             == Set(keys(Korg.solar_abundances)))
    @test Korg.get_mass("CO") ≈ Korg.get_mass("C") + Korg.get_mass("O")
    @test Korg.get_mass("C2") ≈ 2Korg.get_mass("C")
end

@testset "ionization energies" begin
    @test length(Korg.ionization_energies) == 92
    @test Korg.ionization_energies["H"] == [13.5984, -1.000, -1.000]
    @test Korg.ionization_energies["Ru"] == [7.3605, 16.760, 28.470]
    @test Korg.ionization_energies["U"] == [6.1940, 11.590, 19.800]
end


"""
Compute nₑ (number density of free electrons) in a pure Hydrogen atmosphere, where `nH_tot` is the
total number density of H I and H II (in cm⁻³), the temperature is `T`, and `HI_partition_val` is
the the value of the H I partition function.

This is a relatively naive implementation. More numerically stable solutions exist.
"""
function electron_ndens_Hplasma(nH_tot, T, H_I_partition_val = 2.0)
    # Define the Saha equation as: nₑ*n_{H II} / n_{H I} = RHS
    # coef ∼ 4.829e15
    coef = 2.0 * (2.0*π*Korg.electron_mass_cgs*Korg.kboltz_cgs / Korg.hplanck_cgs^2)^1.5
    RHS = coef * T^1.5 * exp(-Korg.RydbergH_eV/(Korg.kboltz_eV*T))/H_I_partition_val
    # In a pure Hydrogen atmosphere: nₑ = n_{H II}. The Saha eqn becomes:  nₑ²/(nH_tot - ne) = RHS
    # We recast the Saha eqn as: a*nₑ² + b*nₑ + c = 0 and compute the coefficients
    a, b, c = (1.0, RHS, -1*RHS*nH_tot)
    # solve quadratic equation. Since b is always positive and c is always negative:
    #    (-b + sqrt(b²-4*a*c))/(2*a) is always ≥ 0
    #    (-b - sqrt(b²-4*a*c))/(2*a) is always negative
    nₑ = (-b + sqrt(b*b-4*a*c))/(2*a)
    nₑ
end

@testset "O I-III and CN partition functions are monotonic in T" begin
    Ts = 1:100:10000
    @test issorted(Korg.partition_funcs["O_I"].(Ts))
    @test issorted(Korg.partition_funcs["O_II"].(Ts))
    @test issorted(Korg.partition_funcs["O_III"].(Ts))
    @test issorted(Korg.partition_funcs["CN_I"].(Ts))
end

@testset "stat mech" begin
    @testset "pure Hydrogen atmosphere" begin
        nH_tot = 1e15
        # specify χs and Us to decouple this testset from other parts of the code
        χs = Dict("H"=>[Korg.RydbergH_eV, -1.0, -1.0])
        Us = Dict(["H_I"=>(T -> 2.0), "H_II"=>(T -> 1.0)])
        # iterate from less than 1% ionized to more than 99% ionized
        for T in [3e3, 4e3, 5e3, 6e3, 7e3, 8e3, 9e3, 1e4, 1.1e4, 1.2e4, 1.3e4, 1.4e4, 1.5e5]
            nₑ = electron_ndens_Hplasma(nH_tot, T, 2.0)
            wII, wIII = Korg.saha_ion_weights(T, nₑ, "H", χs, Us)
            @test wIII ≈ 0.0 rtol = 1e-15
            rtol = (T == 1.5e5) ? 1e-9 : 1e-14
            @test wII/(1 + wII + wIII) ≈ (nₑ/nH_tot) rtol= rtol
        end
    end

    @testset "monotonic N ions Temperature dependence" begin
        weights = [Korg.saha_ion_weights(T, 1.0, "N", Korg.ionization_energies, 
                                            Korg.partition_funcs) for T in 1:100:10000]
        #N II + NIII grows with T === N I shrinks with T
        @test issorted(first.(weights) + last.(weights))
        
        # NIII grows with T
        @test issorted(last.(weights))
    end

    @testset "molecular equilibrium" begin
        #solar abundances
        abundances = Korg.get_absolute_abundances(Korg.atomic_symbols, 0.0, Dict())
        nₜ = 1e15 
        nₑ = 1e-3 * nₜ #arbitrary

        MEQs = Korg.molecular_equilibrium_equations(abundances, Korg.ionization_energies, 
                                                       Korg.partition_funcs, 
                                                       Korg.equilibrium_constants)

        #this should hold for the default atomic/molecular data
        @test Set(MEQs.atoms) == Set(Korg.atomic_symbols)

        n = Korg.molecular_equilibrium(MEQs, 5700.0, nₜ, nₑ)
        #make sure number densities are sensible
        @test n["C_III"] < n["C_II"] < n["C_I"] < n["H_II"] < n["H_I"]

        #total number of carbons is correct
        total_C = map(collect(keys(n))) do species
            if Korg.strip_ionization(species) == "C2"
                n[species] * 2
            elseif ((Korg.strip_ionization(species) == "C") || 
                    (Korg.ismolecule(species) && ("C" in Korg.get_atoms(species))))
                n[species]
            else
                0.0
            end
        end |> sum
        @test total_C ≈ abundances["C"] * nₜ
    end
end

@testset "lines" begin
    @testset "line lists" begin 
        @testset "species codes" begin
            @test Korg.parse_species_code("01.00") == "H_I"
            @test Korg.parse_species_code("01.0000") == "H_I"
            @test Korg.parse_species_code("02.01") == "He_II"
            @test Korg.parse_species_code("02.1000") == "He_II"
            @test Korg.parse_species_code("0608") == "CO_I"
            @test Korg.parse_species_code("0608.00") == "CO_I"
            @test_throws ArgumentError Korg.parse_species_code("06.05.04")
            @test_throws Exception Korg.parse_species_code("99.01")
        end

        @testset "strip ionization info" begin
            @test Korg.strip_ionization("H_I") == "H"
            @test Korg.strip_ionization("H_II") == "H"
            @test Korg.strip_ionization("CO") == "CO"
        end

        @testset "distinguish atoms from molecules" begin
            @test !Korg.ismolecule(Korg.strip_ionization("H_I"))
            @test !Korg.ismolecule(Korg.strip_ionization("H_II"))
            @test Korg.ismolecule(Korg.strip_ionization("CO"))

            @test !Korg.ismolecule("H_I")
            @test !Korg.ismolecule("H_II")
            @test Korg.ismolecule("CO")
        end

        @testset "break molecules into atoms" begin
            @test Korg.get_atoms("CO") == ("C", "O")
            @test Korg.get_atoms("C2") == ("C", "C")
            @test Korg.get_atoms("MgO") == ("Mg", "O")
            #nonsensical but it doesn't matter
            @test Korg.get_atoms("OMg") == ("O", "Mg")
            @test_throws ArgumentError Korg.get_atoms("hello world")
        end

        @test_throws ArgumentError Korg.read_line_list("data/gfallvac08oct17.stub.dat";
                                                          format="abc")

        kurucz_linelist = Korg.read_line_list("data/gfallvac08oct17.stub.dat", format="kurucz")
        @testset "kurucz linelist parsing" begin
            @test issorted(kurucz_linelist, by=l->l.wl)
            @test length(kurucz_linelist) == 988
            @test kurucz_linelist[1].wl ≈ 72320.699 * 1e-8
            @test kurucz_linelist[1].log_gf == -0.826
            @test kurucz_linelist[1].species == "Be_II"
            @test kurucz_linelist[1].E_lower ≈ 17.360339371573698
            @test kurucz_linelist[1].gamma_rad ≈ 8.511380382023759e7
            @test kurucz_linelist[1].gamma_stark ≈ 0.003890451449942805
            @test kurucz_linelist[1].vdW ≈ 1.2302687708123812e-7
        end

        vald_linelist = Korg.read_line_list("data/twolines.vald")
        @testset "vald long format linelist parsing" begin
            @test length(vald_linelist) == 2
            @test vald_linelist[1].wl ≈ 3002.20106 * 1e-8
            @test vald_linelist[1].log_gf == -1.132
            @test vald_linelist[1].species == "Y_II"
            @test vald_linelist[1].E_lower ≈ 3.3757
            @test vald_linelist[1].gamma_rad ≈ 4.1686938347033465e8
            @test vald_linelist[1].gamma_stark ≈ 2.6302679918953817e-6
            @test vald_linelist[1].vdW ≈ 1.9498445997580454e-8

            #test ABO parameters
            @test vald_linelist[2].vdW[1] ≈ 1.3917417470792187e-14
            @test vald_linelist[2].vdW[2] ≈ 0.227
        end

        vald_shortformat_linelist = Korg.read_line_list("data/short.vald")
        @testset "vald short format linelist parsing" begin
            @test length(vald_linelist) == 2
            @test vald_shortformat_linelist[1].wl ≈ 3000.0414 * 1e-8
            @test vald_shortformat_linelist[1].log_gf == -2.957
            @test vald_shortformat_linelist[1].species == "Fe_I"
            @test vald_shortformat_linelist[1].E_lower ≈ 3.3014
            @test vald_shortformat_linelist[1].gamma_rad ≈ 1.905460717963248e7
            @test vald_shortformat_linelist[1].gamma_stark ≈ 0.0001230268770812381
            @test vald_shortformat_linelist[1].vdW ≈ 4.6773514128719815e-8
        end

        moog_linelist = Korg.read_line_list("data/s5eqw_short.moog"; format="moog")
        @testset "moog linelist parsing" begin
            @test issorted(moog_linelist, by=l->l.wl)
            @test moog_linelist[1].wl ≈ 3729.807 * 1e-8
            @test moog_linelist[1].log_gf ≈ -0.280
            @test moog_linelist[1].species == "Ti_I"
            @test moog_linelist[2].E_lower ≈ 3.265
        end

        @test typeof(vald_linelist) == typeof(kurucz_linelist) == typeof(moog_linelist)
    end

    @testset "move_bounds" begin
        a = collect(0.5 .+ (1:9))
        for lb in [1, 3, 9], ub in [1, 5, 9]
            @test Korg.move_bounds(a, lb, ub, 5., 2.) == (3, 6)
            @test Korg.move_bounds(a, lb, ub, 0., 3.) == (1, 2)
            @test Korg.move_bounds(a, lb, ub, 6., 4.) == (2, 9)
            @test Korg.move_bounds(collect(a), lb, ub, 5., 2.) == (3, 6)
            @test Korg.move_bounds(collect(a), lb, ub, 0., 3.) == (1, 2)
            @test Korg.move_bounds(collect(a), lb, ub, 6., 4.) == (2, 9)
        end
    end

    @testset "line profile" begin
        Δ = 0.01
        wls = (4955 : Δ : 5045) * 1e-8
        Δ *= 1e-8
        amplitude = 7.0
        for Δλ_D in [1e-7, 1e-8, 1e-9], Δλ_L in [1e-8, 1e-9]
            ϕ = Korg.line_profile.(5e-5, 1/Δλ_D, Δλ_L, amplitude, wls)
            @test issorted(ϕ[1 : Int(ceil(end/2))])
            @test issorted(ϕ[Int(ceil(end/2)) : end], rev=true)
            @test 0.99 < sum(ϕ .* Δ)/amplitude < 1
        end
    end
end

@testset "atmosphere" begin
    #the MARCS solar model atmosphere
    atmosphere = Korg.read_model_atmosphere("data/sun.krz")
    @test length(atmosphere) == 56
    @test issorted(first.(atmosphere))
    @test atmosphere[1].colmass == 9.747804143e-3
    @test atmosphere[1].temp == 4066.8
    @test atmosphere[1].electron_density == 3.76980e10
    @test atmosphere[1].number_density == 4.75478e14
    @test atmosphere[1].density == 1.00062e-9
end

@testset "synthesis" begin

    @testset "calculate absolute abundances" begin
        @test_throws ArgumentError Korg.get_absolute_abundances(["H"], 0.0, Dict("H"=>13))

        @testset for metallicity in [0.0, 1.0], A_X in [Dict(), Dict("C"=>9)]
            for elements in [Korg.atomic_symbols, ["H", "He", "C", "Ba"]]
                nxnt = Korg.get_absolute_abundances(elements, metallicity, A_X)

                #abundances for the right set of elementns
                @test Set(elements) == Set(keys(nxnt))

                #correct absolute abundances?
                if "C" in keys(A_X)
                    @test log10(nxnt["C"]/nxnt["H"]) + 12 ≈ 9
                end
                @test log10(nxnt["He"]/nxnt["H"]) + 12 ≈ Korg.solar_abundances["He"]
                @test log10(nxnt["Ba"]/nxnt["H"]) + 12 ≈ 
                    Korg.solar_abundances["Ba"] + metallicity

                #normalized?
                if elements == Korg.atomic_symbols
                    @test sum(values(nxnt)) ≈ 1
                else
                    @test sum(values(nxnt)) < 1
                end
            end
        end
    end

    @testset "trapezoid rule" begin
        #gaussian PDF should integral to 1.
        pdf(x) = exp(-1/2 * x^2) / sqrt(2π)
        xs = -10:0.1:10
        @test Korg.trapezoid_rule(xs, pdf.(xs) * 0.1) - 1.0 < 1e-5
    end
end

@testset "LSF" begin
    wls = 5000:0.35:6000
    R = 1800.0
    flux = zeros(Float64, length(wls))
    flux[500] = 5.0

    convF = Korg.constant_R_LSF(flux, wls, R)
    #normalized?
    @test sum(flux) ≈ sum(convF)

    #preserves line center?
    @test argmax(convF) == 500
end
