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

@testset "stat mech" begin
    @testset "pure Hydrogen atmosphere" begin
        nH_tot = 1e15
        # specify χs and Us to decouple this testset from other parts of the code
        χs = [(Korg.RydbergH_eV, -1.0, -1.0)]
        Us = Dict([Korg.species"H_I"=>(T -> 2.0), Korg.species"H_II"=>(T -> 1.0)])
        # iterate from less than 1% ionized to more than 99% ionized
        for T in [3e3, 4e3, 5e3, 6e3, 7e3, 8e3, 9e3, 1e4, 1.1e4, 1.2e4, 1.3e4, 1.4e4, 1.5e5]
            nₑ = electron_ndens_Hplasma(nH_tot, T, 2.0)
            wII, wIII = Korg.saha_ion_weights(T, nₑ, 1, χs, Us)
            @test wIII ≈ 0.0 rtol = 1e-15
            rtol = (T == 1.5e5) ? 1e-9 : 1e-14
            @test wII/(1 + wII + wIII) ≈ (nₑ/nH_tot) rtol= rtol
        end
    end

    @testset "monotonic N ions Temperature dependence" begin
        weights = [Korg.saha_ion_weights(T, 1.0, 7, Korg.ionization_energies, 
                                            Korg.partition_funcs) for T in 1:100:10000]
        #N II + NIII grows with T === N I shrinks with T
        @test issorted(first.(weights) + last.(weights))
        
        # NIII grows with T
        @test issorted(last.(weights))
    end

    @testset "molecular equilibrium" begin
        #solar abundances
        abundances = Korg.get_absolute_abundances(0.0, Dict(), Korg.asplund_2020_solar_abundances, true)
        nₜ = 1e15 
        nₑ = 1e-3 * nₜ #arbitrary

        MEQs = Korg.molecular_equilibrium_equations(abundances, Korg.ionization_energies, 
                                                       Korg.partition_funcs, 
                                                       Korg.equilibrium_constants)
        @test MEQs.atoms == 0x01:Korg.Natoms

        n = Korg.molecular_equilibrium(MEQs, 5700.0, nₜ, nₑ)
        #make sure number densities are sensible
        @test (n[Korg.species"C_III"] < n[Korg.species"C_II"] < n[Korg.species"C_I"] < 
               n[Korg.species"H_II"] < n[Korg.species"H_I"])

        #total number of carbons is correct
        total_C = map(collect(keys(n))) do species
            if species == Korg.species"C2"
                n[species] * 2
            elseif 0x06 in Korg.get_atoms(species.formula)
                n[species]
            else
                0.0
            end
        end |> sum
        @test total_C ≈ abundances[Korg.atomic_numbers["C"]] * nₜ
    end
end

