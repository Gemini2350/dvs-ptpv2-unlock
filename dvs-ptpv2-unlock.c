#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>

#ifdef WIN32
#include <process.h>
#include <stdint.h>
#endif


// ---------------------------------------------------------------------------
// Options are read at RUNTIME from a small config file next to this binary
// (see ConfPath below), so you never have to edit or recompile this file to
// toggle a feature. The #defines here only set the DEFAULTS that apply when
// the config file is missing or does not mention a given key.
//
//   leader=1   allow DVS to become PTP leader   (drops the "-s" slave-only flag)
//   ptpv2=1    enable PTPv2 support             (adds "-y2=-2" and mirrors -m1= to -m2=)
//
// Uncommenting a #define below only changes what happens WITHOUT a config file.
// ---------------------------------------------------------------------------

// #define DEFAULT_ALLOW_LEADER 1	// default: allow DVS to become leader
// #define DEFAULT_ENABLE_PTPV2 1	// default: enable PTPv2 support

#ifndef DEFAULT_ALLOW_LEADER
#define DEFAULT_ALLOW_LEADER 0
#endif
#ifndef DEFAULT_ENABLE_PTPV2
#define DEFAULT_ENABLE_PTPV2 0
#endif

#ifdef WIN32
// DVS may be installed under either Program Files location depending on the
// installer/architecture, so the paths are resolved at startup: whichever
// directory actually holds ptp-original.exe wins (falling back to the first).
#define PATH_MAX_LEN 512
static const char *DvsDirCandidates[] = {
	"C:\\Program Files\\Audinate\\Dante Virtual Soundcard",
	"C:\\Program Files (x86)\\Audinate\\Dante Virtual Soundcard",
};
static char DvsPath[PATH_MAX_LEN];
static char DvsPathArg[PATH_MAX_LEN + 2];
static char ConfPath[PATH_MAX_LEN];

static void resolve_paths(void)
{
	const size_t n = sizeof(DvsDirCandidates) / sizeof(DvsDirCandidates[0]);
	size_t i, chosen = 0;
	char candidate[PATH_MAX_LEN];

	for (i = 0; i < n; i++) {
		FILE *f;
		snprintf(candidate, sizeof candidate, "%s\\ptp-original.exe", DvsDirCandidates[i]);
		f = fopen(candidate, "rb");
		if (f) { fclose(f); chosen = i; break; }
	}
	snprintf(DvsPath, sizeof DvsPath, "%s\\ptp-original.exe", DvsDirCandidates[chosen]);
	snprintf(DvsPathArg, sizeof DvsPathArg, "\"%s\"", DvsPath);
	snprintf(ConfPath, sizeof ConfPath, "%s\\dvs-ptpv2-unlock.conf", DvsDirCandidates[chosen]);
}
#else
const char DvsPath[] = "/Library/Application Support/Audinate/DanteVirtualSoundcard/ptp-original";
#define DvsPathArg DvsPath
const char ConfPath[] = "/Library/Application Support/Audinate/DanteVirtualSoundcard/dvs-ptpv2-unlock.conf";
#endif


// Interpret a config value string as a boolean.
// "1"/"true"/"yes"/"on" (case-insensitive) -> 1; everything else -> 0.
static int parse_bool(const char *v)
{
	while (*v && isspace((unsigned char)*v)) v++;	// trim leading space
	if (strncasecmp(v, "on", 2) == 0)  return 1;
	if (strncasecmp(v, "off", 3) == 0) return 0;
	if (*v == '1' || *v == 'y' || *v == 'Y' || *v == 't' || *v == 'T')
		return 1;
	return 0;
}

// Read the config file (if present) and update *leader / *ptpv2 in place.
// Unknown keys and blank/comment (#) lines are ignored. Values may also be
// overridden by the environment variables DVS_PTP_LEADER / DVS_PTP_PTPV2.
static void load_config(int *leader, int *ptpv2)
{
	FILE *f = fopen(ConfPath, "r");
	if (f) {
		char line[512];
		while (fgets(line, sizeof(line), f)) {
			char *p = line;
			while (*p && isspace((unsigned char)*p)) p++;	// trim leading space
			if (*p == '#' || *p == '\0' || *p == '\n')
				continue;				// comment / blank line
			char *eq = strchr(p, '=');
			if (!eq)
				continue;
			*eq = '\0';
			char *key = p;
			char *val = eq + 1;
			// trim trailing space on key
			char *end = key + strlen(key);
			while (end > key && isspace((unsigned char)end[-1])) *--end = '\0';
			if (strcasecmp(key, "leader") == 0)
				*leader = parse_bool(val);
			else if (strcasecmp(key, "ptpv2") == 0)
				*ptpv2 = parse_bool(val);
		}
		fclose(f);
	}

	const char *env;
	if ((env = getenv("DVS_PTP_LEADER")) != NULL)
		*leader = parse_bool(env);
	if ((env = getenv("DVS_PTP_PTPV2")) != NULL)
		*ptpv2 = parse_bool(env);
}

int main(int argc, char *argv[], char *envp[])
{
	char ** args;
	int i, argsc;

	int allow_leader = DEFAULT_ALLOW_LEADER;
	int enable_ptpv2 = DEFAULT_ENABLE_PTPV2;

#ifdef WIN32
	resolve_paths();	// pick the DVS directory that exists before reading the config
#endif

	load_config(&allow_leader, &enable_ptpv2);

	printf("<3 DVS PTPv2 Unlock <3  (leader=%d ptpv2=%d)\n", allow_leader, enable_ptpv2);

	// upper bound on argument count: original args + PTPv2 additions + NULL
	argsc = argc + 3;

	// store m2 (ptpv2 interface) as used for ptpv1 (-m1=)
	char m2[256] = "-m2=";
	int have_m1 = 0;

	// alloc new argument list (last pointer must always be NULL)
	args = calloc( argsc, sizeof(char*) );

	// set path of actual ptp service
	args[0] = (char*)DvsPathArg;

	for (i = 1, argsc = 1; i < argc; i++) {
		// skip -s (slave-only) option when leader mode is enabled
		if (allow_leader && strcmp(argv[i], "-s") == 0)
			continue;

		if (enable_ptpv2 && strncmp(argv[i], "-m1=", 4) == 0) {
			strncpy(&m2[4], &argv[i][4], sizeof(m2) - 5);
			have_m1 = 1;
		}

#ifdef WIN32
	// the log-file and conf-file paths will be padded with "
	// such that it will be considered one arguments
	// (preventing spaces to mark argument delimiters)
	if ((strncmp(argv[i],"-lf=",4) == 0) ||
	    (strncmp(argv[i],"-c=",3) == 0)){
		int l = strlen(argv[i]);
		args[argsc] = calloc(l+3, sizeof(char));
		args[argsc][0] = '"'; 			// prepend "
		memcpy(&args[argsc][1],argv[i],l);	// original argument
		args[argsc][l+1] = '"';			// append "
		args[argsc][l+2] = '\0';		// string termination
		argsc++;
		continue;
	}
#endif //WIN32

		args[argsc] = argv[i];
		argsc++;
	}

	if (enable_ptpv2) {
		args[argsc++] = "-y2=-2";
		// Only pass -m2= when an interface was actually seen; an empty -m2=
		// makes the real ptp reject the argument list.
		if (have_m1)
			args[argsc++] = m2;
	}

	// call actual ptp service
#ifdef WIN32
	// Unlike execve, _P_WAIT does NOT replace this process: it runs the real ptp
	// as a child and returns its exit status when it finishes. So a normal
	// return is the SUCCESS path -- only -1 means the child failed to start.
	// Returning the child's status keeps DVS's process supervision meaningful.
	{
		intptr_t rc = spawnv(_P_WAIT, DvsPath, args);
		if (rc != -1) {
			free( args );
			return (int)rc;
		}
	}
#else
	execve(args[0], args, envp);
#endif

	// only reached when the real ptp service could not be started

    printf("Error %d starting '%s': ", errno, DvsPath);
    switch(errno){
    	case EPERM: 	printf("Operation not permitted"); break;
    	case ENOENT: 	printf("No such file or directory"); break;
	case EINVAL:	printf("Invalid argument. An invalid value was given for one of the arguments to a function."); break;
    	// etc
    }

	printf("\n");

	free( args );

	return 1;	// starting the real ptp service failed

}
