<%!
    from sailfish import sym
    import sympy
%>

%if 'gravity' in context.keys():
	${const_var} float gravity = ${gravity}f;
%endif

${const_var} float tau0 = ${tau}f;		// relaxation time
${const_var} float tau1 = ${tau_phi}f;		// relaxation time for the order parameter
${const_var} float visc = ${visc}f;		// viscosity

<%def name="bgk_args_decl_sc()">
	float rho, float phi, float *v0, float *ea0, float *ea1
</%def>

<%def name="bgk_args_decl_fe()">
	%if dim == 3:
		float rho, float phi, float lap1, float *v0, float *grad0
	%else:
		float rho, float phi, float lap1, float *v0, float *grad1
	%endif
</%def>

<%namespace file="kernel_common.mako" import="*" name="kernel_common"/>

%if shan_chen:
	${kernel_common.body(bgk_args_decl_sc)}
%else:
	${kernel_common.body(bgk_args_decl_fe)}
%endif

<%namespace file="opencl_compat.mako" import="*" name="opencl_compat"/>
<%namespace file="code_common.mako" import="*"/>
<%namespace file="boundary.mako" import="*" name="boundary"/>
<%namespace file="relaxation.mako" import="*" name="relaxation"/>
<%namespace file="propagation.mako" import="*"/>

<%include file="tracers.mako"/>

<%def name="bgk_args_sc()">
	rho, phi, v, sca1, sca2
</%def>

<%def name="bgk_args_fe()">
	%if dim == 3:
		rho, phi, lap1, v, grad0
	%else:
		rho, phi, lap1, v, grad1
	%endif
</%def>


// A kernel to set the node distributions using the equilibrium distributions
// and the macroscopic fields.
${kernel} void SetInitialConditions(
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist2_in,
	${kernel_args_1st_moment('iv')}
	${global_ptr} float *irho,
	${global_ptr} float *iphi)
{
	${local_indices()}

	%if not shan_chen:
		float lap0, grad0[${dim}];
		float lap1, grad1[${dim}];

		${laplacian_grad_idx()}
		laplacian_and_grad(irho, lap_i, &lap0, grad0);
		laplacian_and_grad(iphi, lap_i, &lap1, grad1);
	%endif

	// Cache macroscopic fields in local variables.
	float rho = irho[gi];
	float phi = iphi[gi];
	float v0[${dim}];

	v0[0] = ivx[gi];
	v0[1] = ivy[gi];
	%if dim == 3:
		v0[2] = ivz[gi];
	%endif

	%for local_var in bgk_equilibrium_vars:
		float ${cex(local_var.lhs)} = ${cex(local_var.rhs, vectors=True)};
	%endfor

	%for i, (feq, idx) in enumerate(bgk_equilibrium[0]):
		${get_odist('dist1_in', i)} = ${cex(feq, vectors=True)};
	%endfor

	%for i, (feq, idx) in enumerate(bgk_equilibrium[1]):
		${get_odist('dist2_in', i)} = ${cex(feq, vectors=True)};
	%endfor
}

${kernel} void PrepareMacroFields(
	${global_ptr} int *map,
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist2_in,
	${global_ptr} float *orho,
	${global_ptr} float *ophi)
{
	${local_indices()}

	int type, orientation;
	decodeNodeType(map[gi], &orientation, &type);

	// Unused nodes do not participate in the simulation.
	if (isUnusedNode(type))
		return;

	%if shan_chen:
		// FIXME: Hackety-hack, should be done properly!
		if (isWallNode(type)) {
			if (gy == 0) {
				orho[gi] = 1.0f;
				ophi[gi] = 0.0f;
			} else {
				orho[gi] = 0.0f;
				ophi[gi] = 1.0f;
			}
			return;
		}
	%endif

	// cache the distributions in local variables
	Dist fi;
	float out;

	getDist(&fi, dist1_in, gi);
	get0thMoment(&fi, type, orientation, &out);
	orho[gi] = out;

	getDist(&fi, dist2_in, gi);
	get0thMoment(&fi, type, orientation, &out);
	ophi[gi] = out;
}

<%def name="laplacian_grad_idx()">
	int lap_i = gi;

	if (gx == 0) {
		lap_i += 1;
	} else if (gx == ${lat_nx-1}) {
		lap_i -= 1;
	}

	if (gy == 0) {
		lap_i += ${lat_nx};
	} else if (gy == ${lat_ny-1}) {
		lap_i -= ${lat_nx};
	}

	%if dim == 3:
		if (gz == 0) {
			lap_i += ${lat_nx}*${lat_ny};
		} else if (gz == ${lat_nz-1}) {
			lap_i -= ${lat_nx}*${lat_ny};
		}
	%endif
</%def>

${kernel} void CollideAndPropagate(
	${global_ptr} int *map,
	${global_ptr} float *dist1_in,
	${global_ptr} float *dist1_out,
	${global_ptr} float *dist2_in,
	${global_ptr} float *dist2_out,
	${global_ptr} float *irho,
	${global_ptr} float *ipsi,
	${kernel_args_1st_moment('ov')}
	int save_macro)
{
	${local_indices()}

	// shared variables for in-block propagation
	%for i in sym.get_prop_dists(grid, 1):
		${shared_var} float prop_${grid.idx_name[i]}[BLOCK_SIZE];
	%endfor
	%for i in sym.get_prop_dists(grid, -1):
		${shared_var} float prop_${grid.idx_name[i]}[BLOCK_SIZE];
	%endfor

	%if not shan_chen:
		${laplacian_grad_idx()}
		float lap1, grad1[${dim}];

		%if dim == 3:
			float lap0, grad0[${dim}];
			laplacian_and_grad(irho, lap_i, &lap0, grad0);
		%endif
		laplacian_and_grad(ipsi, lap_i, &lap1, grad1);
	%else:
		float sca1[${dim}], sca2[${dim}];
		shan_chen_accel(gi, irho, ipsi, sca1, sca2, gx, gy);
	%endif

	int type, orientation;
	decodeNodeType(map[gi], &orientation, &type);

	// Unused nodes do not participate in the simulation.
	if (isUnusedNode(type))
		return;

	// cache the distributions in local variables
	Dist d0, d1;
	getDist(&d0, dist1_in, gi);
	getDist(&d1, dist2_in, gi);

	// macroscopic quantities for the current cell
	float rho, v[${dim}], phi;

	%if not shan_chen:
		getMacro(&d0, type, orientation, &rho, v);
		get0thMoment(&d1, type, orientation, &phi);
	%else:
		float total_dens;
		get0thMoment(&d0, type, orientation, &rho);
		get0thMoment(&d1, type, orientation, &phi);

		compute_1st_moment(&d0, v, 0, 1.0f/tau0);
		compute_1st_moment(&d1, v, 1, 1.0f/tau1);
		total_dens = rho / tau0 + phi / tau1;
		%for i in range(0, dim):
			sca1[${i}] /= rho;
			sca2[${i}] /= phi;
			v[${i}] /= total_dens;
		%endfor

		// FIXME: hack to add a body force acting on one of the components
		sca2[1] -= 0.15f / ${lat_ny};


	%endif

	boundaryConditions(&d0, type, orientation, &rho, v);
	boundaryConditions(&d1, type, orientation, &phi, v);
	${barrier()}

	// only save the macroscopic quantities if requested to do so
	if (save_macro == 1) {
		ovx[gi] = v[0];
		ovy[gi] = v[1];
		%if dim == 3:
			ovz[gi] = v[2];
		%endif
	}

	%if shan_chen:
		${relaxate(bgk_args_sc)}
	%else:
		${relaxate(bgk_args_fe)}
	%endif
	${propagate('dist1_out', 'd0')}
	${barrier()}
	${propagate('dist2_out', 'd1')}
}

