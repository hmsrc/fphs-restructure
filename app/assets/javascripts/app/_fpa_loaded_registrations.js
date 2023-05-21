_fpa.loaded.registrations = () => {

    /**
     https://www.gdpradvisor.co.uk/gdpr-countries
     Austria AT
     Belgium BE
     Bulgaria BG
     Croatia HR
     Cyprus CY
     Czech Republic CZ
     Denmark DK
     Estonia EE
     Finland FI
     France FR
     Germany DE
     Greece GR
     Hungary HU
     Ireland IE
     Italy IT
     Latvia LV
     Lithuania LT
     Luxembourg LU
     Malta MT
     The Netherlands NL
     Poland PL
     Portugal PT
     Romania RO
     Slovakia SK
     Slovenia SI
     Spain ES
     Sweden SW
     United Kingdom GR
     */

    const GDPR_COUNTRY_CODES = ['AT', 'BE', 'BG', 'HR', 'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'GR', 'HU',
        'IE', 'IT', 'LV', 'LU', 'MT', 'NL', 'PL', 'PT', 'RO', 'SK', 'SI', 'ES', 'SW', 'GB'];

    const isGdprCountry = (countryCode) => {
        return GDPR_COUNTRY_CODES.includes(countryCode);
    }

    const gdprTermsOfUse = $('#terms-of-use-gdpr');
    const defaultTermsOfUse = $('#terms-of-use-default');
    const termsOfUseCheckbox = $('user_terms_of_use_accept');

    const handleTermsOfUseContext = (selectElement) => {
        const countryCode = selectElement.val();

        if (!countryCode) {
            defaultTermsOfUse.hide();
            gdprTermsOfUse.hide();
            termsOfUseCheckbox.hide();
            return;
        }

        termsOfUseCheckbox.show();
        if (isGdprCountry(countryCode)) {
            defaultTermsOfUse.hide();
            gdprTermsOfUse.show();
        } else {
            gdprTermsOfUse.hide();
            defaultTermsOfUse.show();
        }
    };

    const countryCodeSelect = $('#user_country_code');
    countryCodeSelect.on('change', (event) => {
        const selectElement = $(event.currentTarget);
        handleTermsOfUseContext(selectElement);
    }).trigger('change');
};
